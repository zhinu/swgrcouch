-- join.lua (G4 Players & launch) - dormant guests in the front end, pad edge polling, the joined set,
-- device (dis)connect events, guest bookkeeping across travel. ARCHITECTURE.md §1.3, §4.2 `join`.
--
-- Game/engine calls (signatures verified with scripts/reflect-func-all.py on the shipping exe):
--   GameplayStatics:SetForceDisableSplitscreen(Object WorldContextObject, Bool bDisable)
--   GameplayStatics:GetPlayerControllerFromID(Object WorldContextObject, Int ControllerID) -> Object
--   GameplayStatics:CreatePlayer(Object WorldContextObject, Int ControllerId, Bool bSpawnPlayerController) -> Object
--   GameplayStatics:RemovePlayer(Object Player, Bool bDestroyPawn)
--   PlayerController:IsInputKeyDown(Struct Key) -> Bool                 (FKey = {KeyName = FName})
--   Widget:SetUserFocus(Object PlayerController)                        (UWidget overload, 1 param)
--   WidgetBlueprintLibrary:SetFocusToGameViewport()                     (static, 0 params)
--   WidgetBlueprintLibrary:SetInputMode_GameAndUIEx(Object PlayerController, Object InWidgetToFocus,
--     Enum InMouseLockMode, Bool bHideCursorDuringCapture, Bool bFlushInput)   5 Lua args (cfg.JoinFocusTrick "gameandui")
--   WidgetBlueprintLibrary:SetInputMode_UIOnlyEx(Object PlayerController, Object InWidgetToFocus,
--     Enum InMouseLockMode, Bool bFlushInput)                                  4 Lua args
--     (reflect-func-all lists an extra "Byte UnderlyingType" before each Enum: the enum's inner property, not a param;
--      EMouseLockMode DoNotLock = 0)
--   Widget:HasUserFocus(Object PlayerController) -> Bool                (keeps P1's focused row on a re-apply)
--   VehiclePawn:Start/StopInputSourceOverride_OnServer(Enum reason)     (1 param; "Byte UnderlyingType" is the enum's inner prop)
--   hooked: GfnGameInstance:OnUserInputDeviceChanged(Enum NewConnectionState, Struct PlatformUserId, Struct InputDeviceId)
--           flags 0x80401 (native); FPlatformUserId = {Int InternalId}; EInputDeviceConnectionState Disconnected=2 Connected=3
--   InputDeviceLibrary (CDO /Script/Engine.Default__InputDeviceLibrary, cfg.DeviceDetectMode poll):
--     GetAllConnectedInputDevices(out Array<FInputDeviceId> OutInputDevices) -> Int      0x4422403
--     GetUserForInputDevice(Struct FInputDeviceId DeviceId) -> Struct FPlatformUserId     0x4022403
--
-- GUEST LIFECYCLE (2026-10-06 crash, crash_2026_10_06_22_02_41*.dmp + UE4SS-run2-crash.log, static analysis with
-- scripts/sig/dis.py, rb-xref.py and the pdata/FNameNativePtrPair tables):
--   run2: tab left 22:02:25 -> RemovePlayer x3 (ok); tab re-entered 22:02:41.6116-.6138 -> CreatePlayer x3 (all
--   returned); AV read 0x20 at exe+0x3800ac ~1 ms later, i.e. in the NEXT engine tick, not inside the Lua call:
--     UGameEngine::Tick (ret 0x1429dd020, called through the UE4SS EngineTick detour) -> Enhanced Input pending
--     rebuild (0x142c0a828: flag +0x14b, vcall +0x110) -> ControlMappingsRebuiltDelegate -> ProcessEvent 0x1438bfdd4
--     -> UInputModeManager::execOnControlMappingsRebuilt 0x140ded7bc (P_FINISH, apply 0x140ded924, then tail-jmp
--     to Broadcast 0x14389d78c of a NATIVE multicast at InputModeManager+0x68) -> raw-method entry (devirtualised
--     branch 0x14389d8eb: no IsSafeToExecute check) -> 0x14038007e: rax = this->[0x70] = 0, read [rax+0x20].
--   0x14038007e is bound once, in ctor 0x14473b6da of a per-LocalPlayer native object (vtable 0x149951f20, built
--   from the LocalPlayer's UFuseUIActionRouter: the CommonUI analog cursor): Router->Outer(LocalPlayer)->
--   GameInstance->GetSubsystem<UUIManager>()+0xe0 (mInputModeManager)+0x68 .AddRaw(this, 0x14038007e); the handle
--   is discarded and neither dtor (0x14453ade0, base 0x14453b690) unbinds. 0x14038007e reads this->[0x70] = the
--   router (its Outer + 0x138 = LocalPlayer subsystems -> GetSubsystem<UEnhancedInputLocalPlayerSubsystem>).
--   => RemovePlayer deinitialises the guest's LocalPlayer subsystems, the analog cursor is freed, and its RAW entry
--   stays in the UIManager (GameInstance lifetime). The next InputModeManager broadcast (any control-mapping
--   rebuild: here the re-created guests' mappings) calls into freed memory. The hazard is not "same ControllerId
--   too soon": EVERY guest RemovePlayer leaves a dangling listener for the rest of the game process.
--   No point in time makes a removal safe: travel/GC only frees the router too (run2: the block was reused 16 s later).
-- Rules implemented here: a guest LocalPlayer is created once and kept until the game exits (tab switches only stop
-- the join poll, races carry it), so creating one is an explicit opt-in (cfg.GuestOptIn): the lobby's ADD PLAYERS row
-- (pressed twice) or F6 (pressed twice); opening the tab alone creates nothing. Then cfg.GuestCreate "connected"
-- creates guests only for pads that are plugged in (an unknown pad state is "not plugged in" until the first device
-- poll). RemovePlayer is never called (cfg.GuestRemoval "launch"/"always" only with cfg.GuestRemovalUnsafe: crash
-- reproducers). A guest that is not joined blocks CONNECT and asks for a second START (its car is then the AI's and
-- it keeps its view); guests that follow a non-couch flow get one view and AI cars (the race_enter guard). Guests
-- also follow the game's own online Multiplayer (split-join to that server): the lobby says to restart first.
-- A ControllerId removed in a world is never re-created in that world (CreatePlayer triggered the fatal broadcast)
-- and after any removal every CreatePlayer is logged as a hazard.
-- LAZY JOIN (couch-livefix, 2026-10-16, cfg.GuestCreate "join", the default): a plugged pad that never joins must not
-- get a LocalPlayer at all. Live round 3: pads 3 / 4 plugged, never joined, got "dormant" LocalPlayers at the "pad
-- plugged in" check (ensureGuests, GuestCreate "connected") and then (1) the race viewport laid out 4 quadrants for 2
-- players (UGameViewportClient::LayoutPlayers counts every LocalPlayer, every frame), (2) the cinematic skip screen
-- and (3) the garage / paddock screens were given to the LAST, dormant, PC. RemovePlayer cannot undo it (above: no
-- removal is ever safe), so nothing is created before the join: swgr_inputfilter.dll's PAD WATCH (inputfix.padWatch /
-- padPresses) reports the A / Start edges of EVERY pad per Slate UserIndex - its GfnRawInput pre-processor on P1's
-- subsystem sees pads that have no LocalPlayer - and join.poll creates the LocalPlayer at the press, already joined.
-- A guest who LEAVES keeps his LocalPlayer (dormant, as before: it cannot be removed) and re-joins through it; the
-- other pads stay LocalPlayer-free. Without the pad watch (DLL missing / old / unknown game build / no
-- FName:GetComparisonIndex) the "connected" rule applies (logged once): dormant guests read the pads as before.
-- bOffsetPlayerGamepadIds (KeyboardIsP1): pad k is Slate user k and ControllerId k+1 (uidFor), as for the filter.
-- VERIFY(V-JOIN-13): pads 3 + 4 plugged, only pad 2 presses A: LocalPlayers = 2 (log "lazy join"), race = 2 views.
-- VERIFY(V-JOIN-11): 10 SPLIT SCREEN <-> other tab switches, no crash, one view, P2 still joins.
-- VERIFY(V-JOIN-12): only with GuestRemoval "launch": a launch that removed a dormant guest survives the race load.

local C        = require("consts")
local cfg      = require("config")
local settings = require("settings")
local St       = require("state")
local U        = require("util")

local M = {}
local TAG = "join"

-- FKey tables, built once on first use (FName construction happens on the game thread).
local KEYS = nil
local function keys()
    if KEYS == nil then
        KEYS = {
            A     = { KeyName = U.fname(C.KEY.A) },
            B     = { KeyName = U.fname(C.KEY.B) },
            Start = { KeyName = U.fname(C.KEY.Start) },
        }
    end
    return KEYS
end

-- Highest guest ControllerId we manage (P1 is ControllerId 0; guests are 1 .. MaxLocalPlayers-1).
local function maxGuestId()
    local n = (tonumber(cfg.MaxLocalPlayers) or 4) - 1
    if n < 0 then n = 0 elseif n > 3 then n = 3 end
    return n
end

local function newSlot(id)
    return { ctrlId = id, joined = false, prevA = false, prevB = false, prevStart = false,
             createdMs = St.nowMs(), disconnected = false, leaving = false,
             aiOverride = false }   -- aiOverride: we put the Disconnect override on this guest's car
end

-- Per-car flags (AI override / handed to the AI) belong to one race: cleared when a guest (re)joins or is kept.
local function resetCarFlags(s)
    s.aiOverride, s.abandoned, s.abandonPending, s.carGen = false, false, false, nil
end

local function status(text)
    U.log(TAG, "%s", text)
    St.emit("status", text)
end

local function phaseMod() return U.mod("phase") end

-- COUCH SEATS (couchseat.lua, FINDING #43): a joined pad sits in a seat (P2 = the first guest to join, P3, P4); the
-- guests' saved progress is keyed by seat, never by ControllerId. seatJoin at every join press: a pad that joins while
-- a joined guest's pad is DISCONNECTED takes over that guest's seat (a pad swap: the old slot is un-joined, it is the
-- same person on another pad); seatLeave at every explicit leave (the seat's progress stays saved for a rejoin).
local function Seat()
    local ok, m = pcall(U.mod, "couchseat")
    return ok and type(m) == "table" and m or nil
end
local function seatJoin(id, why)
    local S = Seat()
    if not S then return nil end
    local seat, displaced = S.join(id, why, function(h)
        local hs = St.join.slots[h]
        return type(hs) == "table" and hs.joined == true and hs.disconnected == true
    end)
    if displaced ~= nil then
        local hs = St.join.slots[displaced]
        if hs then
            hs.joined, hs.leaving, hs.startDownMs, hs.bDownMs = false, false, nil, nil
            resetCarFlags(hs)
        end
        U.log(TAG, "ctrlId %d takes over seat %s from ctrlId %d (its pad is disconnected): ctrlId %d is no longer joined",
            id, tostring(seat), displaced, displaced)
    end
    return seat
end
local function seatLeave(id, why)
    local S = Seat()
    if S then S.leave(id, why) end
end
local abandonCar           -- forward: function(slot, pc) -> bool (defined with the device helpers)

---------------------------------------------------------------------------------------------------
-- Lifecycle bookkeeping (see GUEST LIFECYCLE in the header)
---------------------------------------------------------------------------------------------------

-- cfg.GuestRemoval: "never" (default) | "launch" | "always" (pre-2026-10-07 behaviour: every tab switch removes the
-- guests; crash reproducer only). cfg.GuestCreate: "join" (default, LAZY JOIN) | "connected" | "all".
local function removalMode()
    local m = cfg.GuestRemoval
    if (m == "launch" or m == "always") and cfg.GuestRemovalUnsafe == true then return m end
    return "never"
end

-- kind "launch": a guest that must not follow us into a race / campaign flow (commit, non-couch launch guard).
-- kind "frontend": tab switches, resync after a race, KeyboardIsP1 rebuild, "left mid-race" clean-up.
local function removalAllowed(kind)
    local m = removalMode()
    if m == "always" then return true end
    if m == "never" then return false end
    return kind == "launch"
end

local life = {
    enabledAtMs = nil,  -- St.nowMs() of the ADD PLAYERS opt-in (pad-state wait, see wanted)
    f6AtMs = nil,       -- first F6 of a "create a keyboard guest" pair
    removedIn = {},     -- ctrlId -> St.worldGen of its last RemovePlayer (never re-created in that world)
    removedCount = 0,   -- guest RemovePlayer calls in this game process (hot-reload persisted): dangling listeners
    nextEnsureMs = 0,   -- FAST poll: next "new pad plugged in?" check while the join session is open
    lazyBase = nil,     -- lazy join: uid -> {a, start} pad-watch sequence numbers already consumed (nil = snapshot due)
    lazyLogged = nil,   -- the effective creation rule last logged ("join" | "connected (...)")
}

-- Pad presence per platform user (InternalId): from the device hook (proven to fire at boot, run2-4) and the SLOW
-- InputDeviceLibrary poll. nil = never heard of; true/false = last report.
local padHook = {}
local padPoll = nil        -- last successful poll: uid -> deviceId (nil until a poll succeeded)
local devUser = {}         -- 0.12.0: device InternalId -> the platform user it last connected for (onDeviceState)

local function uidFor(id)
    return id - ((settings.get("KeyboardIsP1") == true) and 1 or 0)
end

-- true / false, or nil when nothing at all is known about pads (no hook event, no successful poll)
local function padConnected(id)
    local uid = uidFor(id)
    if padHook[uid] == false then return false end
    if padHook[uid] == true then return true end
    if padPoll and padPoll[uid] ~= nil then return true end
    if next(padHook) == nil and padPoll == nil then return nil end
    return false
end

-- Guests may be created (cfg.GuestOptIn): after ADD PLAYERS / F6, or when guests already exist (kept from a race,
-- hot reload). Guests live until the game exits, so nothing creates one before the user asked for it.
local function localGuestCount()
    local n = 0
    for _, e in ipairs(U.localPlayers()) do if e.index ~= 1 then n = n + 1 end end   -- Lua table
    return n
end

-- cfg.GuestCreate "join" AND the DLL's pad watch works -> true. Otherwise the "connected" rule (dormant guests).
local function lazyOn()
    if cfg.GuestCreate ~= "join" then return false end
    local ok, on = pcall(function() return U.mod("inputfix").padWatch() == true end)
    local eff = (ok and on) and "join" or ("connected (no pad watch: " .. (ok and "DLL not loaded / old / build unknown"
        or tostring(on)) .. ")")
    if life.lazyLogged ~= eff and (ok and on or M.padsEnabled()) then
        life.lazyLogged = eff
        if ok and on then
            U.log(TAG, "lazy join: a pad gets its LocalPlayer only when it presses %s (no dormant guests)",
                cfg.JoinButtons == "start" and "START" or "A / START")
        else
            U.warn(TAG, "lazy join unavailable, guests created for every plugged pad: GuestCreate %s", eff)
        end
    end
    return ok and on == true
end
M.lazyOn = function() return lazyOn() end

function M.padsEnabled()
    if cfg.GuestOptIn == false then return true end
    if St.join.enabled == true then return true end
    if localGuestCount() > 0 then
        St.join.enabled = true                          -- guests exist already: the opt-in was given earlier
        return true
    end
    return false
end

-- ControllerIds for which join.open keeps (or creates) a guest. An unknown pad state (no device hook event and no
-- successful InputDeviceLibrary poll yet, e.g. right after a hot reload) is "not plugged in": every guest is
-- permanent, so none is created on a guess. Fallback when pad presence stays unknown 5 s after the opt-in (device
-- hook silent AND poll failing): the user asked for players, every id is wanted (logged once).
local function wanted(id)
    if lazyOn() then return false end                   -- lazy join: a LocalPlayer only when the pad joins (poll)
    if cfg.GuestCreate == "all" then return true end
    local c = padConnected(id)
    if c == nil then
        if life.enabledAtMs and St.nowMs() - life.enabledAtMs >= 5000 then
            U.logOnce("join.padunknown", TAG, "WARN pad presence still unknown 5 s after ADD PLAYERS (no device event, "
                .. "device poll failing): guests created for every ControllerId")
            return true
        end
        return false
    end
    return c
end

---------------------------------------------------------------------------------------------------
-- cfg.JoinFocusTrick "gameandui": fallback for a viewport that ignores input (V-JOIN-03)
---------------------------------------------------------------------------------------------------
-- DefaultGame.ini UIManager.bUseUIOnlyInputMode=True [UI§ :258/:689]. In stock UE5 FInputModeUIOnly::ApplyInputMode
-- calls GameViewportClient.SetIgnoreInput(true), and UGameViewportClient::InputKey returns early while IgnoreInput():
-- then NO PlayerController (guest or P1) sees a key, and Slate focus tricks ("userfocus"/"viewport") cannot help.
-- FInputModeGameAndUI clears that flag (viewport-wide) while the widget keeps P1's Slate focus. The game applies its
-- mode natively (UUIManager.mInputModeManager, nothing reflected), so whether it puts UI-only back cannot be read:
-- the mode is re-applied whenever the lobby page is (re)shown and, with cfg.JoinInputModeReapplyMs > 0, periodically.
local gameAndUI = { applied = false, lastMs = 0, lastVisible = nil, count = 0 }

local function lobbyFocusTarget(p1)
    -- RACE SETUP open (setup.lua): the lobby rows are collapsed; P1's focus is on (or returns to) a setup widget
    local okS, sw = pcall(function() return require("setup").focusTarget() end)
    if okS and U.ok(sw) then return sw end
    -- the row P1 currently focuses (a re-apply must not move P1's focus), else the race row
    for _, w in pairs(St.ui.rows or {}) do              -- Lua table (id -> widget)
        if U.ok(w) then
            local ok, has = pcall(U.callMethod, w, "HasUserFocus", p1)
            if ok and has == true then return w end
        end
    end
    local race = St.ui.rows and (St.ui.rows.race or St.ui.rows.quick)   -- 0.13.0 v2: QUICK RACE (no RACE poster)
    if U.ok(race) then return race end
    return nil                                          -- null widget: Slate focus is left unchanged
end

local function applyGameAndUI(why)
    if cfg.JoinFocusTrick ~= "gameandui" then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local target = lobbyFocusTarget(p1)
    -- VERIFY(V-JOIN-03): SetInputMode_GameAndUIEx clears the viewport's ignore-input flag set by the UI-only mode, so
    -- guest pads reach their PlayerInput while P1 keeps navigating the lobby (5 args: pc, widget, lock, hide, flush).
    U.WBL():SetInputMode_GameAndUIEx(p1, target, 0, false, false)
    gameAndUI.applied = true
    gameAndUI.lastMs = St.nowMs()
    gameAndUI.count = gameAndUI.count + 1
    if gameAndUI.count == 1 then
        U.log(TAG, "input mode GameAndUI applied (%s); focus %s", tostring(why), target and "kept on a lobby row" or "unchanged")
    else
        -- the game's InputModeManager may have put UI-only back in between (not readable statically): every
        -- re-apply is logged so the runtime test can correlate it with guests' presses starting to work again
        U.log(TAG, "input mode GameAndUI re-applied (%s, #%d)", tostring(why), gameAndUI.count)
    end
end

-- Undo of applyGameAndUI: the game's own UI-only mode. Front end only (a race sets its own input mode). widget nil =
-- Slate focus left where it is (FInputModeUIOnly focuses only a valid widget), so the game's pane keeps its focus.
local function restoreUIOnly(why)
    if not gameAndUI.applied then return end
    gameAndUI.applied = false
    gameAndUI.lastVisible = nil
    if not phaseMod().isFrontEnd() then return end
    U.try(TAG, function()
        local p1 = U.p1()
        if not U.ok(p1) then return end
        local target = nil
        if St.menu.visible == "lobby" then target = lobbyFocusTarget(p1) end
        -- VERIFY(V-JOIN-03): SetInputMode_UIOnlyEx (4 args: pc, widget, lock, flush) restores the game's menu mode.
        U.WBL():SetInputMode_UIOnlyEx(p1, target, 0, false)
        U.log(TAG, "input mode UI-only restored (%s)", tostring(why))
    end)
end

-- From poll(): re-apply on a lobby (re)show and on the optional period.
local function maintainGameAndUI(now)
    if cfg.JoinFocusTrick ~= "gameandui" then return end
    local vis = St.menu.visible
    local period = tonumber(cfg.JoinInputModeReapplyMs) or 0
    if vis == "lobby" and gameAndUI.lastVisible ~= "lobby" then
        U.try(TAG, applyGameAndUI, "lobby shown")
    elseif vis == "lobby" and period > 0 and now - gameAndUI.lastMs >= period then
        U.try(TAG, applyGameAndUI, "period")
    end
    gameAndUI.lastVisible = vis
end

-- Valid guest PC for a ControllerId, or nil.
-- couch-4p: while couch.lua swaps the pad ids (a shared campaign screen), a local PC's ControllerId is not its own:
-- the screen owner carries P1's id 0 and P1's PC the owner's. Everything here keys guests by their ORIGINAL id
-- (their own pad / slot); couch.originalIdOf gives it (nil when not swapped).
local function couchSwap()
    local c = package.loaded["couch"]
    if type(c) == "table" and type(c.swapped) == "function" then
        local ok, on = pcall(c.swapped)
        if ok and on == true then return c end
    end
    return nil
end

-- U.localPlayers() with each ctrlId = the ORIGINAL id while the couch swap is on (a copy; live ids otherwise).
local function localPlayersOrig()
    local lps = U.localPlayers()
    local c = couchSwap()
    if not c then return lps end
    local out = {}
    for i = 1, #lps do
        local e = lps[i]
        local id = nil
        pcall(function() id = c.originalIdOf(e.pc) end)
        out[i] = { lp = e.lp, pc = e.pc, ctrlId = (type(id) == "number") and id or e.ctrlId, index = e.index }
    end
    return out
end

-- The guest's OWN PlayerController (his PlayerState, his car), whatever pad id it carries now.
local function pcFor(id, world)
    local c = couchSwap()
    if c then
        local okO, own = pcall(c.pcOfOriginalId, id)
        if okO and U.ok(own) then return own end
    end
    world = world or U.world()
    if not U.ok(world) then return nil end
    local pc = U.GS():GetPlayerControllerFromID(world, id)
    if not U.ok(pc) then return nil end
    if c then
        -- swapped and no PC was recorded with this original id: the live holder is someone else's PC
        local okI, orig = pcall(c.originalIdOf, pc)
        if okI and type(orig) == "number" and orig ~= id then return nil end
    end
    return pc
end

-- The PlayerController that reads pad id `id` NOW (the couch swap moves it to another PC): engine lookup.
local function padPcFor(id, world)
    world = world or U.world()
    if not U.ok(world) then return nil end
    local pc = U.GS():GetPlayerControllerFromID(world, id)
    if U.ok(pc) then return pc end
    -- couch.lua's PARK (cfg.CouchSwapPark): during a guest split no PC carries the screen owner's pad id; the PC that
    -- carries it otherwise (P1's) stays the "pad PC", so couchpanel creates the guest's widgets for the same PC as before
    local c = couchSwap()
    if c and type(c.padHolder) == "function" then
        local okH, holder = pcall(c.padHolder, id)
        if okH and U.ok(holder) then return holder end
    end
    return nil
end
M.padPcFor = padPcFor

-- Pad label for a guest ControllerId. KeyboardIsP1=false: pad k drives ControllerId k (pad k+1 1-based);
-- KeyboardIsP1=true: bOffsetPlayerGamepadIds, pad k drives ControllerId k+1. VERIFY(V-JOIN-04): XInput slot order.
local function padLabel(id)
    if settings.get("KeyboardIsP1") == true then return "pad " .. tostring(id) end
    return "pad " .. tostring(id + 1)
end

-- KeyboardIsP1: the pad driving ControllerId 1 (pad 1) is still Slate user 0 = P1's menu user. bOffsetPlayerGamepadIds
-- remaps game input only, not Slate/CommonUI focus routing [UI§4.1-4.2], so that pad's A is consumed by P1's focused
-- row (and B is CommonUI back). That guest joins with Start only, and leaves by HOLDING Start (cfg.LeaveHoldMs): B on
-- that pad would also send CommonUI Back to P1's focused page (the lobby / main menu).
-- VERIFY(V-JOIN-09): with KeyboardIsP1, pad 1's Start reaches ControllerId 1's PlayerInput in the lobby; pad 1 also
-- navigates P1's menus (documented behaviour of this mode).
local function startOnlyFor(id)
    return id == 1 and settings.get("KeyboardIsP1") == true
end

-- Local guests (every local player except P1), from GameInstance.LocalPlayers (engine-pruned owner).
local function localGuests()
    local out = {}
    local lps = localPlayersOrig()
    for i = 1, #lps do                                  -- Lua table returned by U.localPlayers
        local e = lps[i]
        if e.index ~= 1 then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.ctrlId or 0) > (b.ctrlId or 0) end)   -- highest id first
    return out
end

-- True when a LocalPlayer with this ControllerId exists (local object; on a client it exists before the
-- server-spawned PlayerController has replicated).
local function hasLocalPlayer(id)
    local lps = localPlayersOrig()
    for i = 1, #lps do
        if lps[i].index ~= 1 and lps[i].ctrlId == id then return true end
    end
    return false
end

local function removeGuestPC(pc, why, keepPawn)
    if not U.ok(pc) then return false end
    local ok = U.try(TAG, function() U.GS():RemovePlayer(pc, keepPawn ~= true) end)
    U.localPlayersForget()
    U.log(TAG, "RemovePlayer(%s) %s: %s", U.str(pc:GetFName()), why or "", ok and "ok" or "FAILED")
    return ok
end

-- The only path to RemovePlayer for a guest. When cfg.GuestRemoval does not allow `kind`, the guest stays as an
-- un-joined (dormant) LocalPlayer instead. Returns true when the guest was removed (its slot is cleared and its
-- ControllerId is not re-created in this world).
local function dropGuest(id, pc, why, kind, keepPawn)
    if not removalAllowed(kind) then
        local s = (type(id) == "number") and St.join.slots[id] or nil
        if s then
            if s.joined then seatLeave(id, tostring(why)) end
            s.joined, s.leaving, s.startDownMs = false, false, nil
            resetCarFlags(s)
        elseif type(id) == "number" then
            St.join.slots[id] = newSlot(id)
        end
        U.log(TAG, "ctrlId %s kept as a dormant guest (%s, GuestRemoval=%s)", tostring(id), tostring(why), removalMode())
        return false
    end
    if not removeGuestPC(pc, why, keepPawn) then return false end
    if type(id) == "number" then
        seatLeave(id, "removed: " .. tostring(why))
        St.join.slots[id] = nil
        life.removedIn[id] = St.worldGen
    end
    life.removedCount = life.removedCount + 1
    U.warn(TAG, "guest ctrlId %s removed (%s): %d guest RemovePlayer(s) this session; each leaves a dangling "
        .. "input-mode listener (V-JOIN-12)", tostring(id), tostring(why), life.removedCount)
    return true
end

-- Create the guest for ControllerId `id` unless it exists, its pad is not wanted (force: F6 without a pad), or it
-- was removed in this world. joining: the lazy join's press (the caller joins it at once: not logged as dormant).
-- Returns the slot (existing or new) or nil. Never called for a connected client (frozen set).
local function ensureGuest(id, world, why, force, joining)
    local s = St.join.slots[id]
    local pc = U.GS():GetPlayerControllerFromID(world, id)
    if U.ok(pc) then
        if not s then
            s = newSlot(id)                         -- a guest we did not know (kept from a race, hot reload): dormant
            St.join.slots[id] = s
            U.log(TAG, "guest ctrlId %d adopted (%s)", id, padLabel(id))
        end
        return s
    end
    if s and s.joined then
        U.logEvery("join.lostpc" .. id, 10000, TAG, "WARN joined guest ctrlId %d has no PC in the front end", id)
    end
    if not force and not wanted(id) then
        if s and not s.joined then St.join.slots[id] = nil end
        return nil
    end
    if hasLocalPlayer(id) then
        U.logEvery("join.lpnopc" .. id, 10000, TAG, "ctrlId %d has a LocalPlayer but no PC: not re-created", id)
        return s
    end
    if life.removedIn[id] == St.worldGen then
        U.logEvery("join.removed" .. id, 10000, TAG, "ctrlId %d was removed in this world: not re-created before the "
            .. "next world (2026-10-06 crash)", id)
        return nil
    end
    if life.removedCount > 0 then
        U.warn(TAG, "CreatePlayer(%d) after %d guest removal(s) this session: a dangling input-mode listener may be "
            .. "hit by the next mapping rebuild (V-JOIN-12)", id, life.removedCount)
    end
    -- VERIFY(V-JOIN-01): CreatePlayer in the front end gives a BP_GfnPlayerController_C, menu unaffected.
    pc = U.GS():CreatePlayer(world, id, true)
    U.localPlayersForget()
    s = newSlot(id)
    St.join.slots[id] = s
    if U.ok(pc) then
        -- (couch-livefix r4) a lazy join creates the LocalPlayer of a pad that is JOINING (joined right after, never
        -- dormant): round 4's "dormant guest created ... (lazy join)" lines read like a dormant guest
        if joining then
            U.log(TAG, "LocalPlayer created for a joining pad: ctrlId %d (%s, %s)", id, padLabel(id), tostring(why))
        else
            U.log(TAG, "dormant guest created: ctrlId %d (%s, %s)", id, padLabel(id), tostring(why))
        end
    else
        U.warn(TAG, "CreatePlayer(%d) returned no PlayerController", id)
    end
    return s
end

-- All guests the join session should have: existing ones adopted, wanted ones created (only once the pads were
-- enabled, M.padsEnabled). Returns the ids created.
local function ensureGuests(world, why)
    local created = {}
    local create = M.padsEnabled()
    for id = 1, maxGuestId() do
        U.tryEvery("join.ensure", nil, TAG, function()
            local had = U.ok(U.GS():GetPlayerControllerFromID(world, id))
            if not had and not create then return end   -- adopt only
            local s = ensureGuest(id, world, why)
            if s and not had and U.ok(U.GS():GetPlayerControllerFromID(world, id)) then created[#created + 1] = id end
        end)
    end
    return created
end

---------------------------------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------------------------------

-- Guest ControllerIds in view order. The viewport lays the split views out in GameInstance.LocalPlayers order
-- (UGameViewportClient::LayoutPlayers walks GetGamePlayers() by index; UGameInstance::AddLocalPlayer appends).
-- That is NOT ascending ControllerId once guests kept across a race are followed by re-created lower ids
-- (e.g. LocalPlayers [0, 2, 1]), so player numbers follow the array index. Fallback (no GameInstance /
-- empty array): ascending ControllerId.
local function guestIdsInViewOrder()
    local ids, seen = {}, {}
    local lps = localPlayersOrig()                      -- Lua table, LocalPlayers order (index 1 = P1)
    for i = 1, #lps do
        local e = lps[i]
        local id = e.ctrlId
        if e.index ~= 1 and type(id) == "number" and id >= 1 and id <= maxGuestId() and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    for id = 1, maxGuestId() do                         -- slots whose LocalPlayer was not listed: after
        if not seen[id] then ids[#ids + 1] = id end
    end
    return ids
end

-- {{ctrlId, pnum, pc}, ...} in view order (GameInstance.LocalPlayers index); pnum = 1 + rank among the joined
-- guests that have a valid PC [§1.3 player numbers]. Deviation from the §4.2 text "ascending ctrlId": see above.
-- couch-fix40: in RACING the list is built ONCE per loop run (St.loopSeq, like U.localPlayers): pause / finishplate /
-- split.viewSplit / pnumForPC asked for it several times per FAST tick, each build 2 GetPlayerControllerFromID calls
-- per guest (UE4SS wrappers) + the seat reconcile tables. Callers get their own array (entries shared, read-only);
-- a "players" / "world" / "phase" event or a change of the slots' joined flags inside the run builds it again.
local jlCache = { seq = nil, list = nil, fp = nil, gen = nil }
local function jlForget() jlCache.seq, jlCache.list, jlCache.fp, jlCache.gen = nil, nil, nil, nil end
local function slotsFp()
    local fp, n = 0, 0
    for id, s in pairs(St.join.slots) do
        n = n + 1
        if type(id) == "number" and type(s) == "table" and s.joined then fp = fp + id * 31 + 7 end
    end
    return fp * 64 + n
end
pcall(function()
    St.on("players", TAG .. ".jl", jlForget)
    St.on("world", TAG .. ".jl", jlForget)
    St.on("phase", TAG .. ".jl", jlForget)
end)
local joinedListUncached
function M.joinedList()
    local seq = St.loopSeq
    local racing = seq ~= nil and St.phase == "RACING"
    if racing and jlCache.list and jlCache.seq == seq and jlCache.gen == St.worldGen and jlCache.fp == slotsFp() then
        local l, out = jlCache.list, {}
        for i = 1, #l do out[i] = l[i] end
        return out
    end
    local out = joinedListUncached()
    if racing then
        local keep = {}
        for i = 1, #out do keep[i] = out[i] end
        jlCache.seq, jlCache.list, jlCache.fp, jlCache.gen = seq, keep, slotsFp(), St.worldGen
    else
        jlForget()
    end
    return out
end
joinedListUncached = function()
    local out = {}
    local world = U.world()
    if not U.ok(world) then return out end
    local pnum = 1
    local ids = guestIdsInViewOrder()
    -- COUCH SEATS: the seats follow the JOINED slots (a PC missing during a travel keeps its seat); an un-join this
    -- module did not report frees its seat, a joined slot without one gets the lowest free seat
    local S = Seat()
    if S then
        local js = {}
        for k = 1, #ids do
            local s = St.join.slots[ids[k]]
            if s and s.joined then js[#js + 1] = { ctrlId = ids[k], pnum = #js + 2 } end
        end
        U.try(TAG, S.reconcile, js, "joined set")
    end
    for k = 1, #ids do
        local id = ids[k]
        local s = St.join.slots[id]
        if s and s.joined then
            local ok, pc = U.try(TAG, pcFor, id, world)
            if ok and pc then
                pnum = pnum + 1
                -- pc = his own PC; padPc = the PC reading his pad now (another one while couch.lua swaps the ids)
                local okP, padPc = U.try(TAG, padPcFor, id, world)
                out[#out + 1] = { ctrlId = id, pnum = pnum, pc = pc, padPc = (okP and padPc) or pc,
                                  seat = S and S.of(id) or nil }
            end
        end
    end
    return out
end

-- P1 -> 1; a joined guest -> its pnum; anything else -> nil.
function M.pnumForPC(pc)
    if not U.ok(pc) then return nil end
    if U.same(pc, U.p1()) then return 1 end
    local list = M.joinedList()
    for i = 1, #list do
        if list[i].pc == pc then return list[i].pnum end
    end
    return nil
end

-- Display number of ANY local player, unique per local player: P1 -> 1, a joined guest -> its pnum, a local guest
-- that is not joined (a dormant guest accepted with a second START travels with its own view) -> after the joined
-- ones, in view order (1 + #joined + rank). Used for names and HUD tags so that a dormant guest never shares a
-- number with a joined one (feedback 5: dormant ctrlId 1 + joined ctrlId 2 were both "Player 2"). nil = not local.
function M.displayNumForPC(pc)
    if not U.ok(pc) then return nil end
    local n = M.pnumForPC(pc)
    if n then return n end
    local joined = M.joinedList()
    local isJoined = {}
    for i = 1, #joined do isJoined[U.key(joined[i].pc)] = true end
    local rank = 0
    for _, e in ipairs(U.localPlayers()) do
        if e.index ~= 1 and U.ok(e.pc) and not isJoined[U.key(e.pc)] then
            rank = rank + 1
            if U.same(e.pc, pc) then return 1 + #joined + rank end
        end
    end
    return nil
end

-- P1 + joined guests with a valid PC.
function M.localHumanCount()
    return 1 + #M.joinedList()
end

function M.isFrozen()
    return St.join.frozen == true
end

-- Guests that exist (LocalPlayer with a PC) but are not joined: {{ctrlId, label}, ...}, ascending ctrlId. They
-- cannot be removed (RemovePlayer crash), so a launch or connect would carry them (extra view / ghost racer on a host).
function M.dormantList()
    local out = {}
    for _, e in ipairs(localGuests()) do                -- Lua table
        local s = St.join.slots[e.ctrlId]
        if U.ok(e.pc) and not (s and s.joined) then
            out[#out + 1] = { ctrlId = e.ctrlId, label = string.upper(padLabel(e.ctrlId or 0)) }
        end
    end
    table.sort(out, function(a, b) return (a.ctrlId or 0) < (b.ctrlId or 0) end)
    return out
end

-- "PAD 3 IS NOT JOINED" / "PADS 3, 4 ARE NOT JOINED", or nil when every guest is joined.
function M.dormantText()
    local list = M.dormantList()
    if #list == 0 then return nil end
    if #list == 1 then return list[1].label .. " IS NOT JOINED" end
    local nums = {}
    for _, d in ipairs(list) do nums[#nums + 1] = (d.label:gsub("^PAD ", "")) end
    return "PADS " .. table.concat(nums, ", ") .. " ARE NOT JOINED"
end

-- Lobby ADD PLAYERS row (confirmed) / F6 pair: the explicit opt-in for permanent guest LocalPlayers.
function M.enablePads(why)
    if St.join.frozen == true then
        status("DISCONNECT TO CHANGE PLAYERS")
        return false
    end
    if not phaseMod().isFrontEnd() or St.launch.pending then
        status("ADD PLAYERS ONLY IN THE MENU")
        return false
    end
    local first = St.join.enabled ~= true
    -- lazy join: the DLL's pad watch must run before the first poll (it is loaded early, with P1 alone)
    if cfg.GuestCreate == "join" then
        pcall(function() U.mod("inputfix").ensureNative("ADD PLAYERS: lazy join") end)
    end
    St.join.enabled = true
    life.enabledAtMs = life.enabledAtMs or St.nowMs()
    life.nextEnsureMs = 0                               -- join.poll creates the guests of plugged-in pads now
    if first then
        U.log(TAG, "pads enabled (%s): guest LocalPlayers are created for plugged-in pads and kept until the game "
            .. "exits", tostring(why))
    end
    if St.join.active then
        local world = U.world()
        if U.ok(world) then
            local now = St.nowMs()
            local created = ensureGuests(world, "add players")
            for _, id in ipairs(created) do             -- Lua table
                local sl = St.join.slots[id]
                if sl then sl.createdMs = now; sl.prevA, sl.prevB, sl.prevStart = true, true, true end
            end
        end
    end
    status("PADS ON UNTIL GAME RESTART: PRESS A ON A PAD TO JOIN")
    St.emit("players")
    return true
end

-- Four card texts for the Lobby (§1.2): P1, then joined guests by pnum (view order), then open slots.
function M.slotViews()
    local views = {}
    if settings.get("KeyboardIsP1") == true then
        views[1] = "P1  READY  (keyboard)"
    else
        views[1] = "P1  READY  (pad 1)"
    end
    local i = 2
    local joined = M.joinedList()
    for k = 1, #joined do
        local e = joined[k]
        local s = St.join.slots[e.ctrlId]
        if s.disconnected then
            views[i] = string.format("P%d  CONTROLLER DISCONNECTED", e.pnum)
        elseif s.leaving then
            views[i] = string.format("P%d  LEAVES AFTER THIS RACE", e.pnum)
        else
            local leaveKey = startOnlyFor(e.ctrlId) and "HOLD START = leave" or "B = leave"
            views[i] = string.format("P%d  READY  %s  (%s)", e.pnum, leaveKey, padLabel(e.ctrlId))
        end
        i = i + 1
    end
    local world = U.world()
    for id = 1, maxGuestId() do
        if i > 4 then break end
        local s = St.join.slots[id]
        if not (s and s.joined and pcFor(id, world)) then
            if St.join.frozen then
                views[i] = "--  DISCONNECT TO CHANGE PLAYERS"
            elseif St.join.active and s and pcFor(id, world) then
                if s.disconnected then
                    views[i] = string.format("--  CONTROLLER DISCONNECTED (%s)", padLabel(id))
                elseif startOnlyFor(id) or cfg.JoinButtons == "start" then
                    views[i] = string.format("--  press START to join (%s)", padLabel(id))
                else
                    views[i] = string.format("--  press A to join (%s)", padLabel(id))
                end
            elseif St.join.active and not M.padsEnabled() then
                views[i] = (i == 2) and "--  ADD PLAYERS (BELOW) TO JOIN WITH PADS" or "--"
            elseif St.join.active and life.removedIn[id] == St.worldGen and not pcFor(id, world) then
                views[i] = string.format("--  %s: AVAILABLE AFTER THE NEXT RACE", string.upper(padLabel(id)))
            elseif St.join.active and cfg.GuestCreate ~= "all" and padConnected(id) == false then
                views[i] = string.format("--  connect %s to join", padLabel(id))
            elseif St.join.active and padConnected(id) == true and lazyOn() then
                -- lazy join: a plugged pad without a LocalPlayer joins with its A (join.poll creates it then)
                views[i] = (startOnlyFor(id) or cfg.JoinButtons == "start")
                    and string.format("--  press START to join (%s)", padLabel(id))
                    or string.format("--  press A to join (%s)", padLabel(id))
            else
                views[i] = "--  EMPTY"
            end
            i = i + 1
        end
    end
    while i <= 4 do views[i] = "--"; i = i + 1 end
    return views
end

-- UI v2 players strip (notes/design/ui-v2/ui-redesign-final.md §4.3, §12.2, WI-14): the four cells as data, in
-- slotViews' order and with its rules (P1, the joined guests by pnum, then the open guest ids ascending):
--   {kind, pnum, ctrlId, pad, leaveKey, joinKey, leaveHold}
--   kind: "host" (P1, pad or keyboard) | "ready" | "disconnected" | "leaving" (joined guests) | "join" (a dormant
--     guest: its pad can join) | "connect" (no pad plugged in for that id, or the dormant guest's pad is gone) |
--     "padsoff" (ADD PLAYERS not given yet) | "later" (removed in this world: available after the next race) |
--     "frozen" (a connected client) | "empty";
--   pnum = the cell's player number (P1..P4; a joined guest's own pnum); ctrlId = the ControllerId (P1 0; nil for a
--   cell past cfg.MaxLocalPlayers); pad = "PAD 2" | "KEYBOARD" (P1 with KeyboardIsP1); leaveKey = "B" | "START" for a
--   joined guest; leaveHold = true when leaving needs the key held (Start always; B only on the RACERS step: in the
--   lobby a B press leaves at once); joinKey = "A" | "START" for an open cell (START: KeyboardIsP1's pad-1 guest, or
--   cfg.JoinButtons = "start"). New tables per call. slotViews stays for the classic lobby.
function M.slotStates()
    local out = {}
    local function pad(id) return string.upper(padLabel(id)) end
    local function joinKey(id) return (startOnlyFor(id) or cfg.JoinButtons == "start") and "START" or "A" end
    local holdB = false
    pcall(function() holdB = U.mod("setup").guestBHoldsToLeave() == true end)
    out[1] = { kind = "host", pnum = 1, ctrlId = 0,
               pad = (settings.get("KeyboardIsP1") == true) and "KEYBOARD" or "PAD 1" }
    local i = 2
    local joined = M.joinedList()
    for k = 1, #joined do
        if i > 4 then break end
        local e = joined[k]
        local s = St.join.slots[e.ctrlId] or {}
        local startLeave = startOnlyFor(e.ctrlId)
        local kind = "ready"
        if s.disconnected then kind = "disconnected" elseif s.leaving then kind = "leaving" end
        out[i] = { kind = kind, pnum = e.pnum, ctrlId = e.ctrlId, pad = pad(e.ctrlId),
                   leaveKey = startLeave and "START" or "B", leaveHold = startLeave or holdB }
        i = i + 1
    end
    local world = U.world()
    for id = 1, maxGuestId() do
        if i > 4 then break end
        local s = St.join.slots[id]
        local pc = pcFor(id, world)
        if not (s and s.joined and pc) then
            local kind
            if St.join.frozen then
                kind = "frozen"
            elseif St.join.active and s and pc then
                kind = s.disconnected and "connect" or "join"
            elseif St.join.active and not M.padsEnabled() then
                kind = "padsoff"
            elseif St.join.active and life.removedIn[id] == St.worldGen and not pc then
                kind = "later"
            elseif St.join.active and cfg.GuestCreate ~= "all" and padConnected(id) == false then
                kind = "connect"
            elseif St.join.active and padConnected(id) == true and lazyOn() then
                kind = "join"                       -- lazy join: no LocalPlayer yet, its A creates one (join.poll)
            else
                kind = "empty"
            end
            out[i] = { kind = kind, pnum = i, ctrlId = id, pad = pad(id), joinKey = joinKey(id) }
            i = i + 1
        end
    end
    while i <= 4 do
        out[i] = { kind = "empty", pnum = i, ctrlId = nil, pad = pad(i - 1), joinKey = joinKey(i - 1) }
        i = i + 1
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Lifecycle: open / close / commit / rebuild / resync
---------------------------------------------------------------------------------------------------

-- Start the join session on the lobby [§1.3 Open]: adopt the guests that exist, create the wanted missing ones (one
-- view kept by force-disabling split screen) and arm the edge poll. Re-entrant: re-opening the tab never re-creates
-- a guest, and a ControllerId removed in this world is never re-created in it (2026-10-06 crash, header).
function M.open()
    if U.netMode() == "client" then
        St.join.frozen = true
        status("DISCONNECT TO CHANGE PLAYERS")
        St.emit("players")
        return false
    end
    if not phaseMod().isFrontEnd() then
        U.warn(TAG, "open refused: not in the front end (phase %s)", tostring(St.phase))
        return false
    end
    if St.launch.pending or St.phase == "LAUNCHING" then
        -- launch.start already committed the guest set: new dormant guests would travel into the race.
        status("LAUNCHING...")
        return false
    end
    local world = U.world()
    if not U.ok(world) then return false end
    local wasActive = (St.join.active == true)
    life.lazyBase = nil           -- lazy join: presses made before this session never join (fresh snapshot)
    if cfg.GuestCreate == "join" and M.padsEnabled() then
        pcall(function() U.mod("inputfix").ensureNative("join session: lazy join") end)
    end
    St.join.active = true
    St.join.frozen = false
    St.join.keep = false          -- a commit that was not followed by travel (refused launch) is undone here
    -- VERIFY(V-JOIN-02): only P1's view renders while guests exist in the front end.
    U.GS():SetForceDisableSplitscreen(world, true)
    local now = St.nowMs()
    -- cfg.GuestOptIn: guests are only adopted here until the user enabled the pads (ADD PLAYERS / F6)
    local created = ensureGuests(world, wasActive and "re-open" or "open")
    life.nextEnsureMs = now + 1000
    local n = 0
    for id, s in pairs(St.join.slots) do                -- Lua table (not a TArray)
        U.try(TAG, function()
            -- re-arm the edge detector: a button held while the lobby opens never counts as a press
            s.createdMs = now
            s.prevA, s.prevB, s.prevStart = true, true, true
            s.startDownMs = nil
            local pc = pcFor(id, world)
            if pc then n = n + 1 end
            if pc and cfg.JoinFocusTrick == "userfocus" and U.ok(St.menu.lobby) then
                -- VERIFY(V-JOIN-03): gives the guest's Slate user a focused widget so its pad reaches its PC.
                St.menu.lobby:SetUserFocus(pc)
            end
        end)
    end
    U.log(TAG, "join session open: %d guest(s) (%d created now, pads %s, %d removal(s) this session, GuestCreate=%s)",
        n, #created, M.padsEnabled() and "enabled" or "not enabled (ADD PLAYERS)", life.removedCount,
        tostring(cfg.GuestCreate or "connected"))
    if cfg.JoinFocusTrick == "viewport" then
        U.try(TAG, function()
            -- VERIFY(V-JOIN-03): focuses every Slate user on the viewport; P1 is refocused on the race row.
            U.WBL():SetFocusToGameViewport()
            U.mod("ui").focus(St.ui.rows.race or St.ui.rows.quick)
        end)
    elseif cfg.JoinFocusTrick == "gameandui" then
        -- VERIFY(V-JOIN-03): fallback for a viewport that ignores input in the UI-only front end (see applyGameAndUI)
        U.try(TAG, applyGameAndUI, "open")
        gameAndUI.lastVisible = St.menu.visible
    end
    St.emit("players")
    return true
end

local function ensureSingleView(why)
    U.try(TAG, function() U.mod("split").frontEndSingleView(why) end)
end

-- Stop the join session (tab left, lobby hidden, return chain given up) [§1.3 Close, revised 2026-10-07]. The guests
-- are KEPT, joined or not: the poll stops (their input is ignored) and the front end keeps one view. Re-opening the
-- tab re-arms them; nothing is re-created. cfg.GuestRemoval "always" restores the old removal (crash reproducer).
function M.close(why)
    why = why or "close"
    if removalAllowed("frontend") then
        M.removeAll(why, "frontend")
        return
    end
    local was = (St.join.active == true)
    St.join.active = false
    St.join.keep = false
    restoreUIOnly(why)
    if phaseMod().isFrontEnd() then ensureSingleView(why) end
    if was then U.log(TAG, "join session closed (%s): %d guest(s) kept, input ignored", why, #localGuests()) end
    St.emit("players")
end

-- Remove every guest, joined or not, highest ControllerId first, where cfg.GuestRemoval allows `kind` (kind defaults
-- to "launch": guests that must not follow a non-couch flow); otherwise the guests stay as un-joined LocalPlayers.
-- Returns removed, kept.
function M.removeAll(why, kind)
    why, kind = why or "removeAll", kind or "launch"
    St.join.active = false
    St.join.keep = false
    restoreUIOnly(why)
    local guests = localGuests()
    local removed, kept = 0, 0
    for i = 1, #guests do
        local e = guests[i]
        if U.ok(e.pc) then
            if dropGuest(e.ctrlId, e.pc, why, kind) then removed = removed + 1 else kept = kept + 1 end
        else
            U.warn(TAG, "local player ctrlId %s has no PlayerController; cannot remove it", tostring(e.ctrlId))
            kept = kept + 1
        end
    end
    for id, s in pairs(St.join.slots) do                -- Lua table; drop slots without a LocalPlayer
        if not hasLocalPlayer(id) then St.join.slots[id] = nil else resetCarFlags(s) end
    end
    if phaseMod().isFrontEnd() then
        ensureSingleView(why)
    elseif kept == 0 then
        U.try(TAG, function()
            local world = U.world()
            if U.ok(world) then U.GS():SetForceDisableSplitscreen(world, false) end
        end)
    end
    if removed + kept > 0 then
        U.log(TAG, "%s: %d guest(s) removed, %d kept (GuestRemoval=%s)", why, removed, kept, removalMode())
    end
    St.emit("players")
    return removed, kept
end

-- takeover.leaveMidRace (§3.6, a taken-over local guest leaves): RemovePlayer only where cfg.GuestRemoval allows
-- it (kind "launch"); returns true when removed. Otherwise the guest's LocalPlayer stays and its slot is untouched
-- (join.keyboardLeave marks it leaving; join.resync un-joins it in the next front end).
function M.removeGuest(pc, why)
    if not U.ok(pc) then return false end
    if not removalAllowed("launch") then
        U.log(TAG, "%s: guest kept (GuestRemoval=%s)", tostring(why), removalMode())
        return false
    end
    local id = nil
    for _, e in ipairs(U.localPlayers()) do             -- Lua table
        if e.index ~= 1 and U.same(e.pc, pc) then id = e.ctrlId end
    end
    return dropGuest(id, pc, why or "removeGuest", "launch", true)   -- RemovePlayer(pc, false): the car is the AI's
end

-- menu_tab.closeStrayGuests (game tab selected, switcher shows a game pane, return chain failed, phase OTHER from
-- the menu). Only leaving the front end into a non-couch flow removes guests; everything else just closes the join
-- session (the guests stay for the whole front-end visit). menu_tab already skips a pending launch.
function M.closeStray(why)
    if St.launch.pending or M.isFrozen() then return end
    local leaving = type(why) == "string" and why:find("phase OTHER", 1, true) ~= nil
    if leaving or removalAllowed("frontend") then
        if #localGuests() > 0 then M.removeAll(why, leaving and "launch" or "frontend") end
        return
    end
    if St.join.active then M.close(why) end
end

-- Right before launch/connect: joined guests travel with us [§1.3 Commit]. Force-disable stays on until the race
-- map (split.enterRace). A dormant (un-joined) guest cannot be removed (RemovePlayer crash): net.connect refuses while
-- one exists (M.dormantText), launch.start only goes ahead with one after a second START (the user accepted an
-- AI-driven car in that guest's view), and builder (devscreen) refuses. Such a guest is parked here: abandonPending,
-- so raceTick hands its car to the AI.
function M.commit()
    local guests = localGuests()
    local parked = 0
    for i = 1, #guests do
        local e = guests[i]
        local s = St.join.slots[e.ctrlId]
        if not (s and s.joined) then
            if not dropGuest(e.ctrlId, e.pc, "commit (dormant)", "launch") then
                -- GuestRemoval "never": the dormant guest travels; its car goes to the AI (raceTick), its view stays
                local sl = St.join.slots[e.ctrlId]
                if sl then sl.abandonPending = true end
                parked = parked + 1
            end
        end
    end
    St.join.active = false
    St.join.keep = true          -- the joined set must survive the coming travel (read by resync)
    restoreUIOnly("commit")
    U.log(TAG, "commit: %d joined guest(s) kept", #M.joinedList())
    if parked > 0 then
        U.warn(TAG, "commit: %d dormant guest(s) travel with us (GuestRemoval=never): AI drives their cars", parked)
        status(parked == 1 and "1 PAD NOT JOINED: ITS CAR IS AI-DRIVEN" or
            string.format("%d PADS NOT JOINED: THEIR CARS ARE AI-DRIVEN", parked))
    end
    St.emit("players")
end

-- KeyboardIsP1 changed: pad k now drives another ControllerId. Nothing is removed or re-created (2026-10-06 crash):
-- open() re-arms the existing guests and creates the newly wanted ids. Only allowed with no joined guest.
function M.rebuild()
    if St.join.frozen == true then
        status("DISCONNECT TO CHANGE PLAYERS")
        return false
    end
    -- joined slots, not only joinedList(): a joined slot whose PC is not (yet) there must block a rebuild too
    for _, s in pairs(St.join.slots) do                 -- Lua table (not a TArray)
        if s.joined then
            status("REMOVE GUESTS FIRST")
            return false
        end
    end
    if removalAllowed("frontend") then M.removeAll("rebuild", "frontend") end
    return M.open()
end

-- Listener: phase -> FRONTEND. Picks up the guests that survived travel (their LocalPlayers persist,
-- their PCs are new), removes guests that left mid-race, and decides whether the guest set is kept.
-- (A refused launch never leaves FRONTEND, so it does not come through here: launch.start re-opens the join
-- screen itself in that case.)
function M.resync()
    -- A client's guest set changes only through DISCONNECT (§2.3). Coming back to a standalone front end after an
    -- unplanned drop (network failure, host fell back to a local OpenLevel, HostTravelFallback relisten) keeps the
    -- set: the auto-rejoin must reconnect with the same guests. Read before frozen is recomputed.
    local wasFrozen = (St.join.frozen == true)
    local wantConn = (St.net.wantConnected == true)
    local isClient = (U.netMode() == "client")
    -- Frozen also while a rejoin is wanted (standalone front end after a drop, auto-rejoin armed): lobby.onShown,
    -- lobby.onHidden and closeStrayGuests must neither add dormant guests nor close the joined ones that the rejoin
    -- carries (§2.4). net un-freezes (slowTick / onFrontEnd) once wantConnected turns false.
    St.join.frozen = isClient or wantConn
    local world = U.world()
    for id, s in pairs(St.join.slots) do                -- Lua table (not a TArray)
        U.try(TAG, function()
            local pc = pcFor(id, world)
            if s.leaving and isClient then
                -- connected client: a removal would leave a ghost on the host (see keyboardLeave); the guest stays
                -- until DISCONNECT (hot-reload leftovers only: a client's F7 is refused in a race)
                U.warn(TAG, "client guest ctrlId %d marked leaving: kept until DISCONNECT", id)
                s.leaving, s.abandonPending = false, false
                if not s.joined then St.join.slots[id] = nil end
            elseif s.leaving then
                -- GuestRemoval "never"/"launch": the guest stays as a dormant LocalPlayer (no dangling listener)
                -- and can join again; with "launch" the next couch launch drops it if it does not.
                if pc then dropGuest(id, pc, "left mid-race", "frontend") else St.join.slots[id] = nil end
            elseif s.joined and not pc then
                if isClient and hasLocalPlayer(id) then
                    -- Client: the guest's PC is spawned by the server after the engine split-join round trip and
                    -- may replicate after FRONTEND is detected. Keep the slot joined; joinedList()/pcFor() skip
                    -- it until the PC exists.
                    -- VERIFY(V-JOIN-08): a client's split-join guests get their PC within a few seconds of FRONTEND.
                    U.log(TAG, "client guest ctrlId %d: PC not replicated yet; slot stays joined", id)
                else
                    -- VERIFY(V-JOIN-07): joined guests keep their LocalPlayer and get a new PC after travel.
                    U.warn(TAG, "joined guest ctrlId %d has no PC after travel; slot un-joined", id)
                    s.joined = false
                end
            end
            -- per-car flags belong to the race just left (a guest kept here races again only after a new commit)
            resetCarFlags(s)
        end)
    end
    -- A frozen (client) guest set is never closed here: it only changes through DISCONNECT (net un-freezes).
    local keep = (St.join.frozen == true) or wasFrozen or wantConn or ((cfg.ReturnToSplitTab == true)
        and (St.ui.returnToTab == true or St.join.keep == true or St.join.active == true
             or St.menu.visible == "lobby"))
    St.join.keep = false
    if not keep then
        M.close("resync: not returning to the FREE MODE tab")   -- guests kept, join session closed
    elseif St.menu.visible == "lobby" and not St.join.frozen and not St.join.active then
        M.open()                                      -- the lobby page survived the round trip (rare)
    else
        St.emit("players")
    end
    U.log(TAG, "resync: frozen=%s (was %s, wantConnected %s) keep=%s joined=%d", tostring(St.join.frozen),
        tostring(wasFrozen), tostring(wantConn), tostring(keep), #M.joinedList())
end

---------------------------------------------------------------------------------------------------
-- FAST poll: rising edges of A/Start (join) and B (leave) on guest PCs [§1.3 Edge poll]
---------------------------------------------------------------------------------------------------

-- LAZY JOIN (header): the DLL's pad watch -> a LocalPlayer, already joined, for a pad that has none and pressed A
-- (Start too with cfg.JoinWithStart; Start only for startOnlyFor / JoinButtons "start") since this session opened.
-- pads = inputfix.padPresses() ({[uid] = {down, a, start, b}}). -> true when a guest joined
local function lazyJoinTick(world, now, pads)
    if type(pads) ~= "table" then return false end
    if life.lazyBase == nil then                        -- first poll of the session: what was pressed before is spent
        life.lazyBase = {}
        for uid, e in pairs(pads) do life.lazyBase[uid] = { a = e.a or 0, start = e.start or 0 } end
        return false
    end
    local changed = false
    for id = 1, maxGuestId() do
        local uid = uidFor(id)
        local cur = pads[uid] or {}
        local base = life.lazyBase[uid] or { a = 0, start = 0 }
        local aNew = (cur.a or 0) > (base.a or 0)
        local sNew = (cur.start or 0) > (base.start or 0)
        life.lazyBase[uid] = { a = cur.a or 0, start = cur.start or 0 }
        local startOnly = (cfg.JoinButtons == "start") or startOnlyFor(id)
        local press = ((not startOnly) and aNew) or ((cfg.JoinWithStart or startOnly) and sNew)
        if press and not U.ok(U.GS():GetPlayerControllerFromID(world, id)) and not hasLocalPlayer(id) then
            if life.removedIn[id] == St.worldGen then
                U.logEvery("join.lazyremoved" .. id, 10000, TAG, "%s pressed to join: removed in this world, not "
                    .. "re-created before the next world", padLabel(id))
            else
                local s = ensureGuest(id, world, "pad pressed to join (lazy join)", true, true)
                local pc = U.GS():GetPlayerControllerFromID(world, id)
                if s and U.ok(pc) then
                    s.joined, s.disconnected = true, false
                    resetCarFlags(s)
                    s.createdMs = now
                    s.prevA, s.prevB, s.prevStart = true, true, true   -- the join press is still down: never a leave
                    s.aWas, s.aDownMs = (cur.down or 0) % 2 == 1, now   -- guestPressWithin: P1's CommonUI drops it
                    seatJoin(id, "lazy join")
                    changed = true
                    U.log(TAG, "lazy join: %s pressed %s -> LocalPlayer created for ctrlId %d, joined", padLabel(id),
                        aNew and "A" or "START", id)
                    status(string.format("P%d JOINED", M.pnumForPC(pc) or (id + 1)))
                end
            end
        end
    end
    return changed
end
M._lazyJoinTick = lazyJoinTick                          -- tests

function M.poll()
    if not St.join.active then return end
    if St.launchHold() then return end              -- 0.12.0: the front end is being torn down (state.lua)
    if not phaseMod().isFrontEnd() then return end
    local world = U.world()
    if not U.ok(world) then return end
    local k = keys()
    local now = St.nowMs()
    maintainGameAndUI(now)
    local arm = tonumber(cfg.JoinArmMs) or 300
    -- cfg.JoinButtons: "a_or_start" (default; Start only with cfg.JoinWithStart) | "start" (A never joins)
    local startOnly = (cfg.JoinButtons == "start")
    local changed = false
    -- lazy join: a pad without a LocalPlayer joins at its press (the DLL's pad watch), nothing is created before
    if M.padsEnabled() and lazyOn() then
        local okP, pads = pcall(function() return U.mod("inputfix").padPresses() end)
        if okP then
            local okT, joinedNow = U.try(TAG, lazyJoinTick, world, now, pads)
            if okT and joinedNow then changed = true end
        end
    end
    -- A pad plugged in while the lobby is open gets its guest (cfg.GuestCreate "connected"), at most once a second,
    -- once the pads were enabled (cfg.GuestOptIn). Only from here (FAST loop, game thread), never from the device
    -- hook callback itself.
    if now >= (life.nextEnsureMs or 0) and M.padsEnabled() then
        life.nextEnsureMs = now + 1000
        local created = ensureGuests(world, "pad plugged in")
        for c = 1, #created do
            local sl = St.join.slots[created[c]]
            if sl then sl.createdMs = now; sl.prevA, sl.prevB, sl.prevStart = true, true, true end
            changed = true
        end
    end
    for id = 1, maxGuestId() do
        local s = St.join.slots[id]
        if s then
            U.tryEvery("join.poll", nil, TAG, function()
                local pc = U.GS():GetPlayerControllerFromID(world, id)
                if not U.ok(pc) then
                    s.prevA, s.prevB, s.prevStart = false, false, false
                    s.aWas = false                                      -- no stale "A down" for guestPressWithin
                    return
                end
                -- VERIFY(V-JOIN-03): guest pad input reaches PlayerInput in the UI-only front end (fallbacks:
                -- cfg.JoinFocusTrick "userfocus" | "viewport" for Slate focus, "gameandui" for a viewport that ignores input).
                -- VERIFY(V-JOIN-06): P1's pad never shows up on a guest PC.
                local slotStartOnly = startOnly or startOnlyFor(id)       -- VERIFY(V-JOIN-09)
                local a = pc:IsInputKeyDown(k.A) == true
                -- 0.12.0 (review fix, task #14): the raw A edges of every guest pad, for M.guestPressWithin (the v2
                -- lobby's START tile drops a click that is a guest's A reaching P1's CommonUI focus)
                if a ~= (s.aWas == true) then
                    if a then s.aDownMs = now else s.aUpMs = now end
                    s.aWas = a
                end
                local st = false
                if cfg.JoinWithStart or slotStartOnly then st = pc:IsInputKeyDown(k.Start) == true end
                -- VERIFY(V-JOIN-06): fallback cfg.JoinButtons = "start" when P1's A also reaches a guest PC.
                local join = (not slotStartOnly and a) or st
                -- the pad-0 guest of KeyboardIsP1 (startOnlyFor) leaves by holding Start: its B is P1's CommonUI Back.
                -- The hold is timed from a Start press made while already joined (the join press never counts).
                local holdLeave = startOnlyFor(id)
                local b = false
                if holdLeave then
                    if not (s.joined and st) then
                        s.startDownMs = nil
                    elseif not s.prevStart then
                        s.startDownMs = now
                    end
                    b = s.startDownMs ~= nil and now - s.startDownMs >= (tonumber(cfg.LeaveHoldMs) or 1000)
                else
                    b = pc:IsInputKeyDown(k.B) == true
                    -- RACE SETUP's VEHICLES step: a quick B is the guest's "un-ready / row back" (setup.pollGuests);
                    -- leaving needs B held for cfg.LeaveHoldMs
                    local holdB = false
                    pcall(function() holdB = U.mod("setup").guestBHoldsToLeave() == true end)
                    if holdB and s.joined then
                        if not b then s.bDownMs = nil elseif not s.bDownMs then s.bDownMs = now end
                        b = s.bDownMs ~= nil and now - s.bDownMs >= (tonumber(cfg.LeaveHoldMs) or 1000)
                    else
                        s.bDownMs = nil
                    end
                end
                if now - (s.createdMs or 0) >= arm then
                    if not s.joined and join and not s.prevA then
                        s.joined = true
                        s.disconnected = false
                        resetCarFlags(s)
                        seatJoin(id, "join press")
                        changed = true
                        status(string.format("P%d JOINED", M.pnumForPC(pc) or (id + 1)))
                    elseif s.joined and b and not s.prevB then
                        local pnum = M.pnumForPC(pc) or (id + 1)
                        s.joined = false
                        s.startDownMs = nil
                        seatLeave(id, "left in the lobby (B)")
                        changed = true
                        status(string.format("P%d LEFT", pnum))
                    end
                end
                s.prevA, s.prevB, s.prevStart = join, b, st
            end)
        end
    end
    if changed then St.emit("players") end
end

-- (couch-livefix e) a joined guest leaves the COUCH CAMPAIGN (couch.leaveTick: B held cfg.LeaveHoldMs in the paddock /
-- post-race, outside a guest area). His LocalPlayer stays (dormant, as a lobby leave): the couch rules and the dormant-
-- screen swap take it from there. -> true when he left
function M.campaignLeave(id, why)
    local s = St.join.slots[id]
    if not (s and s.joined) then return false end
    local pnum = nil
    pcall(function() pnum = M.pnumForPC(pcFor(id)) end)
    s.joined = false
    s.startDownMs, s.bDownMs = nil, nil
    seatLeave(id, tostring(why))
    status(string.format("P%d LEFT", pnum or (id + 1)))
    U.log(TAG, "guest ctrlId %d left the couch campaign (%s): his local player stays (dormant)", id, tostring(why))
    St.emit("players")
    return true
end

-- 0.12.0 (review fix, task #14: a guest's A also clicks P1's focused menu widget): a guest pad's A is down, or went down
-- or up within ms, as join.poll last read it (main's FAST loop runs join.poll before ui.pollClicks). -> ctrlId, age in
-- ms | nil. The v2 lobby focuses START by default (spec §4.6), so its START tile drops such a click (racers.lua has the
-- same guard on P1's sink, V-RC-07).
function M.guestPressWithin(ms)
    if not St.join.active then return nil end
    ms = tonumber(ms) or 150
    local now = St.nowMs()
    for id = 1, maxGuestId() do
        local s = St.join.slots[id]
        if s then
            if s.aWas then return id, 0 end
            if s.aDownMs and now - s.aDownMs <= ms then return id, now - s.aDownMs end
            if s.aUpMs and now - s.aUpMs <= ms then return id, now - s.aUpMs end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Keyboard test path (F6 / F7, §1.8). keys.lua wraps the calls in sched.run (game thread).
---------------------------------------------------------------------------------------------------

function M.keyboardJoin()
    local ph = phaseMod()
    if ph.isFrontEnd() then
        if St.launch.pending or St.phase == "LAUNCHING" then
            status("LAUNCHING...")
            return
        end
        if not St.join.active then
            U.mod("menu_tab").selectOurTab()          -- opening the tab opens the join screen
            return
        end
        local world = U.world()
        for id = 1, maxGuestId() do
            local s = St.join.slots[id]
            if s and not s.joined and pcFor(id, world) then
                s.joined = true
                s.disconnected = false
                resetCarFlags(s)
                seatJoin(id, "keyboard join")
                status(string.format("P%d JOINED (keyboard)", M.pnumForPC(pcFor(id, world)) or (id + 1)))
                St.emit("players")
                return
            end
        end
        -- no dormant guest (no pad plugged in for it, cfg.GuestCreate "connected"): F6 creates the lowest free one.
        -- That guest is a LocalPlayer kept until the game exits (it can never be removed): a second F6 within 2 s
        -- confirms it.
        for id = 1, maxGuestId() do
            if not pcFor(id, world) and not hasLocalPlayer(id) and life.removedIn[id] ~= St.worldGen then
                local now = St.nowMs()
                if not (life.f6AtMs and now - life.f6AtMs <= 2000) then
                    life.f6AtMs = now
                    status("F6 AGAIN: ADD A KEYBOARD GUEST (KEPT UNTIL GAME RESTART)")
                    return
                end
                life.f6AtMs = nil
                St.join.enabled = true                  -- an explicit opt-in, like ADD PLAYERS
                life.enabledAtMs = life.enabledAtMs or now
                U.warn(TAG, "F6: creating a keyboard guest (ctrlId %d); it stays until the game exits", id)
                local _, s = U.try(TAG, ensureGuest, id, world, "F6", true)
                if type(s) == "table" and pcFor(id, world) then
                    s.joined = true
                    seatJoin(id, "F6 keyboard guest")
                    s.createdMs = St.nowMs()
                    s.prevA, s.prevB, s.prevStart = true, true, true
                    status(string.format("P%d JOINED (keyboard)", M.pnumForPC(pcFor(id, world)) or (id + 1)))
                    St.emit("players")
                end
                return
            end
        end
        status("NO FREE PLAYER SLOT")
        return
    end
    if not ph.isRace() then return end
    if not (cfg.AllowMidRaceJoin and U.isServer()) then
        U.log(TAG, "F6 in a race: mid-race join is disabled (cfg.AllowMidRaceJoin)")
        return
    end
    -- Debugging path only: a PC created after the grid exists has no native slot -> takeover [PS§8 #6].
    -- Never in a campaign race: the takeover is off there (possessing a campaign AI car crashes the game natively,
    -- exe+0x641579), so the new PC would only be a carless player; he joins at the next paddock / front end instead.
    local okB, blocked = pcall(function() return U.mod("takeover").blockedHere() end)
    if okB and type(blocked) == "string" then
        U.log(TAG, "F6 in a race: mid-race join refused in a %s (no AI takeover there)", blocked)
        status("JOIN AFTER THIS RACE")
        return
    end
    local world = U.world()
    for id = 1, maxGuestId() do
        if not pcFor(id, world) and not hasLocalPlayer(id) and life.removedIn[id] ~= St.worldGen then
            local pc = U.GS():CreatePlayer(world, id, true)
            U.localPlayersForget()
            if not U.ok(pc) then
                U.warn(TAG, "mid-race CreatePlayer(%d) failed", id)
                return
            end
            local s = newSlot(id)
            s.joined = true
            St.join.slots[id] = s
            seatJoin(id, "mid-race join")
            local tko = U.mod("takeover")
            local car = tko.pickCar(U.gs())
            if car then
                tko.takeOver(pc, car)
            else
                U.warn(TAG, "mid-race join: no free AI car for ctrlId %d", id)
            end
            St.emit("players")
            return
        end
    end
    status("NO FREE PLAYER SLOT")
end

function M.keyboardLeave()
    local list = M.joinedList()
    local ph = phaseMod()
    -- In a race a removed guest stays joined (slot.leaving) until the next front end: each F7 acts on the highest
    -- joined guest that is not already leaving (never a second leaveMidRace / Disconnect override on one car).
    local last = nil
    for i = #list, 1, -1 do
        local sl = St.join.slots[list[i].ctrlId]
        if not (ph.isRace() and sl and sl.leaving) then
            last = list[i]
            break
        end
    end
    if not last then
        status("NO GUEST TO REMOVE")
        return
    end
    local s = St.join.slots[last.ctrlId]
    if ph.isFrontEnd() then
        if St.join.frozen then
            -- connected client: the split-join guest stays on the host until DISCONNECT (§2.3)
            status("DISCONNECT TO CHANGE PLAYERS")
            return
        end
        s.joined = false
        seatLeave(last.ctrlId, "F7 in the menu")
        status(string.format("P%d LEFT (keyboard)", last.pnum))
        St.emit("players")
        return
    end
    if ph.isRace() then
        if U.netMode() == "client" or St.join.frozen then
            -- Connected client: removing the LocalPlayer here (or in the next, still connected, front end) is not
            -- seen by the host (UGameInstance::RemoveLocalPlayer only destroys an authoritative PC, no split-leave
            -- message): the host would keep a ghost remote player with a grid car. Same rule as the front end.
            status("DISCONNECT TO CHANGE PLAYERS")
            return
        end
        if U.isServer() then
            U.mod("takeover").leaveMidRace(last.pc)     -- release or Disconnect override [§3.6]
        end
        s.leaving = true                                -- the LocalPlayer goes away in the next front end
        status(string.format("P%d LEAVES AFTER THIS RACE", last.pnum))
        St.emit("players")
    end
end

---------------------------------------------------------------------------------------------------
-- Device (dis)connect: post-hook on GfnGameInstance:OnUserInputDeviceChanged [§1.3 Device events]
---------------------------------------------------------------------------------------------------

local function applyCarOverride(s, ctrlId, connected)
    if not (cfg.AIOnPadDisconnect and U.isServer() and phaseMod().isRace()) then return end
    -- A guest that left mid-race (F7: takeover.leaveMidRace started its own Disconnect override, s.aiOverride untouched)
    -- or whose car was handed to the AI for good (abandonCar / race_enter guard) keeps the AI: a pad unplug must not
    -- stack a second override, and a replug must not give the car back to a player who has no view.
    if s.leaving or s.abandonPending or s.abandoned then return end
    local pc = pcFor(ctrlId)
    if not pc then return end
    local car = pc.Pawn
    if not U.isVehicle(car) then return end
    if not connected and not s.aiOverride then
        car:StartInputSourceOverride_OnServer(C.E.Override.Disconnect)    -- the game's own human->AI path
        s.aiOverride = true
        U.log(TAG, "ctrlId %d pad lost: Disconnect override started on its car", ctrlId)
    elseif connected and s.aiOverride then
        car:StopInputSourceOverride_OnServer(C.E.Override.Disconnect)
        s.aiOverride = false
        U.log(TAG, "ctrlId %d pad back: Disconnect override stopped", ctrlId)
    end
end

-- Hand a guest's car to the AI for good (race not launched by the mod, see onRaceEnter). Server only. The
-- Disconnect override is the game's own human->AI path; s.aiOverride records that it is on (never stopped: the
-- guest leaves in the next front end).
abandonCar = function(s, pc)
    local car = pc.Pawn
    if not U.isVehicle(car) then return false end
    car:StartInputSourceOverride_OnServer(C.E.Override.Disconnect)   -- (Enum reason), 1 param
    s.aiOverride = true
    s.abandoned = true                                  -- applyCarOverride never touches this car again
    s.abandonPending = false
    U.log(TAG, "ctrlId %s: car handed to the AI (race not launched by SWGRCouch)", tostring(s.ctrlId))
    return true
end

-- 0.8.1 (2026-10-07, "just make it dynamic put me as p1"): a pad that CONNECTS while the game runs and belongs to no
-- local player becomes P1's controller (a Moonlight/Sunshine pad vanishes and comes back with every client connection,
-- often behind other pads). cfg.HotplugPadToP1: "front" (default: in the front end; during a race it is applied at
-- the next front end) | "always" | "off". Never with couch pads enabled (ADD PLAYERS: the pad joins as a guest), never
-- for a pad a local player already uses, never during the boot enumeration.
-- 0.12.0 (review hyg-3; a couch-over-Moonlight test setup of 2026-10-08 had to turn the rule off: "the second
-- Moonlight pad must join as P2, never take P1"): only while P1's own pad is gone (its disconnect was seen: the Moonlight / Sunshine reconnect case), never with
-- KeyboardIsP1 (the keyboard is P1). A second pad switched on at the menu next to a working P1 pad stays free for
-- ADD PLAYERS.
-- VERIFY(V-JOIN-20): connect a pad mid-session -> "[join] hot-plugged pad ctrlId N takes P1 (was ctrlId M): ok".
local pendingP1 = nil
local frontSinceMs = nil

-- diag / tests: true / false / nil (nothing known) for a ControllerId's pad
function M.padPresent(ctrlId) return padConnected(ctrlId) end
function M.hotplugToP1(ctrlId, why)
    local mode = cfg.HotplugPadToP1
    if mode == nil then mode = "front" end
    if mode == "off" or mode == false then return false, "off" end
    if M.padsEnabled() then return false, "couch pads enabled" end
    if St.phase ~= "FRONTEND" and mode ~= "always" then
        pendingP1 = ctrlId
        U.log(TAG, "hot-plugged pad ctrlId %d: takes P1 at the next front end (%s)", ctrlId, tostring(why))
        return false, "deferred"
    end
    if settings.get("KeyboardIsP1") == true then return false, "KeyboardIsP1" end
    local gs, p1 = U.GS(), U.p1()
    if not (U.ok(gs) and U.ok(p1)) then return false, "no P1" end
    for _, e in ipairs(U.localPlayers()) do
        local okI, id = pcall(function() return gs:GetPlayerControllerID(e.pc) end)
        if okI and id == ctrlId then return false, "already P" .. tostring(e.index) .. "'s pad" end
    end
    local was = -1
    pcall(function() was = gs:GetPlayerControllerID(p1) end)
    if padConnected(was) ~= false then
        U.log(TAG, "hot-plugged pad ctrlId %d: P1 keeps ctrlId %s, whose pad is still connected (ADD PLAYERS makes the "
            .. "new pad a guest) (V-JOIN-20)", ctrlId, tostring(was))
        return false, "P1's pad still connected"
    end
    local ok, err = pcall(function() gs:SetPlayerControllerID(p1, ctrlId) end)
    U.log(TAG, "hot-plugged pad ctrlId %d takes P1 (was ctrlId %s; %s): %s (V-JOIN-20)", ctrlId, tostring(was),
        tostring(why), ok and "ok" or tostring(err))
    if ok then status("NEW CONTROLLER IS PLAYER 1") end
    return ok
end

function M.hotplugTick()
    if St.phase ~= "FRONTEND" then frontSinceMs = nil; return end
    frontSinceMs = frontSinceMs or St.nowMs()
    if pendingP1 and St.nowMs() - frontSinceMs > 1500 then
        local id = pendingP1
        pendingP1 = nil
        U.try(TAG, M.hotplugToP1, id, "deferred from the race")
    end
end

-- One (dis)connect of a platform user's pad, from the hook or the device poll. Idempotent: a state the slot already
-- has is ignored (cfg.DeviceDetectMode "both" reports every change twice).
function M.onDeviceState(st, uid, dev, source)
    -- VERIFY(V-JOIN-05): PlatformUserId.InternalId equals the pad's ControllerId (minus 1 with KeyboardIsP1).
    local kb = (settings.get("KeyboardIsP1") == true) and 1 or 0
    local ctrlId = (tonumber(uid) or -1) + kb
    -- 0.12.0: the hook reports a disconnect with user -1 (UE unmaps the device before the broadcast; live 2026-10-10
    -- "state=2 user=-1 device=4"). Pad presence (padHook: the hot-plug rule, GuestCreate "connected") and P1's status
    -- then go to the user this device last connected for; the guest slots below keep the reported user (their hook
    -- disconnect handling stays as it was in 0.11).
    local u, d = tonumber(uid), tonumber(dev)
    local presence = u
    if d and d >= 0 then
        if st == C.E.DeviceConn.Connected and u and u >= 0 then devUser[d] = u
        elseif st == C.E.DeviceConn.Disconnected and (u == nil or u < 0) and devUser[d] ~= nil then presence = devUser[d] end
    end
    U.log(TAG, "device %s: state=%s user=%s device=%s -> ctrlId %d%s", tostring(source or "event"),
        tostring(st), tostring(uid), tostring(dev), ctrlId,
        presence ~= u and string.format(" (the pad of user %d)", presence) or "")
    if st ~= C.E.DeviceConn.Disconnected and st ~= C.E.DeviceConn.Connected then return end
    local connected = (st == C.E.DeviceConn.Connected)
    -- 0.8.1: hot-plug -> P1 (not during the boot enumeration: the front end must have been up for 5 s)
    if connected and frontSinceMs and St.nowMs() - frontSinceMs > 5000 then
        U.try(TAG, M.hotplugToP1, ctrlId, tostring(source or "event"))
    end
    -- pad presence for cfg.GuestCreate "connected" (join.poll creates the guest; never from this callback)
    if type(presence) == "number" then padHook[presence] = connected end
    if ctrlId < 1 or ctrlId > maxGuestId() then
        if not connected and presence ~= nil and presence + kb == 0 then status("P1 CONTROLLER DISCONNECTED") end
        return
    end
    local s = St.join.slots[ctrlId]
    if not s then
        if St.join.active then St.emit("players") end   -- lobby card "connect pad k"; join.poll creates the guest
        return
    end
    if s.disconnected == (not connected) then return end
    s.disconnected = not connected
    if s.joined then
        local pnum = M.pnumForPC(pcFor(ctrlId)) or (ctrlId + 1)
        status(string.format(connected and "P%d CONTROLLER RECONNECTED" or "P%d CONTROLLER DISCONNECTED", pnum))
        U.try(TAG, applyCarOverride, s, ctrlId, connected)
    end
    St.emit("players")
end

local lastDeviceHookMs = nil     -- St.nowMs() of the last device hook call (pollDevices' "hook" watchdog)

function M.onDevice(ctx, NewConnectionState, PlatformUserId, InputDeviceId)
    lastDeviceHookMs = St.nowMs()
    if cfg.DeviceDetectMode == "poll" then return end
    local st = NewConnectionState:get()
    local uid = PlatformUserId:get().InternalId
    local dev = -1
    U.try(TAG, function() dev = InputDeviceId:get().InternalId end)
    M.onDeviceState(st, uid, dev, "hook")
end

-- SLOW loop, cfg.DeviceDetectMode "both" | "poll": backup for a device hook that never fires (V-JOIN-10). The set of
-- platform users with a connected device is diffed against the previous poll; each edge goes through onDeviceState.
local devPoll = { users = nil }      -- InternalId -> true (nil = no baseline yet)

-- Platform user -> one of its connected GAMEPAD devices. The default input device (keyboard + mouse, owned by the
-- primary user 0) is left out: with KeyboardIsP1, pad 0 drives ControllerId 1 but also belongs to user 0, and the
-- keyboard would keep user 0 "present" after that pad is gone (P2's pad loss never reported). A user counts as
-- connected while it has at least one non-default device.
local function connectedUsers()
    local lib = U.cdo("InputDeviceLibrary")
    if not U.ok(lib) then return nil end
    -- UInputDeviceLibrary:GetDefaultInputDevice() -> Struct FInputDeviceId (static, 0 params) [reflect-func-all]
    -- VERIFY(V-JOIN-10): the default device is the keyboard/mouse device, distinct from every gamepad's id.
    local defaultDev = nil
    U.try(TAG, function()
        local d = lib:GetDefaultInputDevice()
        local id = type(d) == "table" and d.InternalId or U.unwrap(d).InternalId
        if type(id) == "number" then defaultDev = id end
    end)
    -- couch-racegc: a FRESH out table each call (its LocalUnrealParam elements belong to this call), registered and its
    -- registry refs dropped right after: UE4SS luaL_ref's an out-param table (LuaUObject.cpp:220) and only reads the
    -- ref inside that call. Before, every call (SLOW loop, once a second) left a {1,2} / {1,2,3} table of
    -- LocalUnrealParam elements in the registry for the whole session (live 2026-10-15: 717 -> 1368 entries).
    local out = St.outParams and St.outParams({}) or {}
    -- VERIFY(V-JOIN-10): the array out-param table is filled in place with FInputDeviceId elements (params or
    -- struct userdata: unwrapped by U.arrayToTable) [API§9 out params].
    local okD, errD = pcall(U.callMethod, lib, "GetAllConnectedInputDevices", out)
    if St.dropOutRefs then St.dropOutRefs(out) end
    if not okD then error(errD, 0) end
    local users = {}
    for _, d in ipairs(U.arrayToTable(out)) do
        U.try(TAG, function()
            local devId = d.InternalId
            if devId == nil or devId == defaultDev then return end
            local user = lib:GetUserForInputDevice({ InternalId = devId })   -- struct by value -> Lua table
            local uid = type(user) == "table" and user.InternalId or U.unwrap(user).InternalId
            if type(uid) == "number" and uid >= 0 and users[uid] == nil then users[uid] = devId end
        end)
    end
    return users
end

-- cfg.DeviceDetectMode "hook": the device hook is a native (flags 0x80401) that may be bound with AddUObject and never
-- pass through ProcessEvent [API§4]; nothing else would notice a pad lost mid-race. The poll then runs as an
-- edge-only watchdog: no baseline report (a mapping problem of the poll, V-JOIN-10, would otherwise hand every
-- guest's car to the AI at once), and an edge is applied only when no hook event came in the last 3 s (the hook
-- fires on the change itself, before the 1 s poll sees it, and stays authoritative while it works).
local HOOK_RECENT_MS = 3000

function M.pollDevices()
    local mode = cfg.DeviceDetectMode
    local watchdog = (mode ~= "both" and mode ~= "poll")
    local ok, users = U.try(TAG, connectedUsers)
    if not ok or type(users) ~= "table" then return end
    padPoll = users                                     -- cfg.GuestCreate "connected" (padConnected)
    local prev = devPoll.users
    devPoll.users = users
    if watchdog then
        if prev == nil then return end
        if lastDeviceHookMs and St.nowMs() - lastDeviceHookMs < HOOK_RECENT_MS then return end
        for uid, dev in pairs(users) do
            if prev[uid] == nil then
                U.warn(TAG, "device poll: user %s connected without a device hook call (V-JOIN-10 watchdog)", tostring(uid))
                M.onDeviceState(C.E.DeviceConn.Connected, uid, dev, "poll-watchdog")
            end
        end
        for uid, dev in pairs(prev) do
            if users[uid] == nil then
                U.warn(TAG, "device poll: user %s disconnected without a device hook call (V-JOIN-10 watchdog)",
                    tostring(uid))
                M.onDeviceState(C.E.DeviceConn.Disconnected, uid, dev, "poll-watchdog")
            end
        end
        return
    end
    if prev == nil then
        -- baseline: a joined guest whose pad is absent already is reported once
        for id, s in pairs(St.join.slots) do
            local uid = id - ((settings.get("KeyboardIsP1") == true) and 1 or 0)
            if s.joined and users[uid] == nil then
                M.onDeviceState(C.E.DeviceConn.Disconnected, uid, -1, "poll")
            end
        end
        return
    end
    for uid, dev in pairs(users) do
        if prev[uid] == nil then M.onDeviceState(C.E.DeviceConn.Connected, uid, dev, "poll") end
    end
    for uid, dev in pairs(prev) do
        if users[uid] == nil then M.onDeviceState(C.E.DeviceConn.Disconnected, uid, dev, "poll") end
    end
end

-- MAIN loop, race phases, server: the pad-loss override for a guest whose car did not exist yet when the pad went
-- away (launched disconnected, or lost during LOADING / the grid spawn) is applied as soon as the car exists.
function M.raceTick()
    -- Per-car flags belong to the race world whose car they were applied to (s.carGen). A new race world reached
    -- without a front end in between (relisten `open <map>?listen`, servertravel restart, a game-native restart) has
    -- new cars: the old flags are reset here (join.resync only runs on FRONTEND). A guest that left (F7: leaving) or
    -- whose car was handed to the AI (abandoned) gets its NEW car handed to the AI too (abandonPending, below), and a
    -- guest whose pad is still disconnected gets the Disconnect override again (AIOnPadDisconnect loop, below).
    -- Otherwise both cars would stand still and could hold the results (WaitForAllPlayersToFinish waits on every
    -- Racers entry). carGen is adopted on the first raceTick of the world in which a flag was set (also restored
    -- flags after a hot reload).
    local gen = St.worldGen
    for id, s in pairs(St.join.slots) do
        local flagged = s.aiOverride or s.abandoned or s.abandonPending or s.leaving
        if flagged and s.carGen == nil then
            s.carGen = gen
        elseif s.carGen ~= nil and s.carGen ~= gen then
            U.log(TAG, "ctrlId %s: new race world (gen %s -> %s): per-car flags reset%s", tostring(id),
                tostring(s.carGen), tostring(gen), (s.leaving or s.abandoned) and ", new car goes to the AI" or "")
            s.carGen = gen
            s.aiOverride = false
            if s.leaving or s.abandoned then
                s.abandoned = false
                s.abandonPending = true
            end
        end
    end
    -- guests of a race the mod did not launch (onRaceEnter): their car is handed to the AI once it exists
    for id, s in pairs(St.join.slots) do
        if s.abandonPending and not s.aiOverride then
            U.try(TAG, function()
                local pc = pcFor(id)
                if pc then abandonCar(s, pc) end
            end)
        end
    end
    if not cfg.AIOnPadDisconnect then return end
    for id, s in pairs(St.join.slots) do
        if s.joined and s.disconnected and not s.aiOverride and not s.leaving then
            U.try(TAG, applyCarOverride, s, id, false)
        end
    end
end

---------------------------------------------------------------------------------------------------
-- init: hooks and listeners only (no UFunction calls) [§4.2 main boot step 3]
---------------------------------------------------------------------------------------------------

-- "race_enter"(new, from) (phase.lua, before the "phase" event of the first race phase): a race entered from the
-- front end that the mod did not launch (Campaign/Arcade/Scenarios started while guests were still alive, e.g. a
-- return to our tab that did not land) must not get split views, guest HUDs or takeovers: guests are removed first.
-- A connected client's races are always ours (the host launched them).
-- In LOADING no car exists yet: the guests are removed (join.close). The MAIN poll may first see the race in PRERACE
-- or later (LOADING skipped): a guest that already owns a car or a racer entry must not lose its PC now (destroying
-- it destroys its PlayerState = the racer entry [PS§7]); its car goes to the AI (the game's own Disconnect override)
-- and the guest leaves in the next front end (slot.leaving -> join.resync). Guests without either are removed. The
-- race then shows one view (St.race.singleView, read by split.enterRace and hud.tick).
local RACE_PHASES = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }

local function onRaceEnter(new, from)
    -- From the menu (FRONTEND/LAUNCHING) and from OTHER (campaign paddock, PvP flow: entered from the menu without
    -- a tab event, kept rematch guests may still be alive). Not after BOOT (hot reload mid-race) nor LEAVING (the
    -- next race of a relisten / servertravel).
    if from == "BOOT" or from == "LEAVING" or from == "TRANSIT" or RACE_PHASES[from] then return end
    if St.race.launchedByUs == true or U.netMode() == "client" or St.net.wantConnected == true then return end
    local okC, couch = pcall(function() return U.mod("couch").active() end)
    if okC and couch == true then
        local dorm = M.dormantList()
        U.log(TAG, "COUCH CAMPAIGN race (from %s): %d joined guest(s) keep their cars, split screen stays%s",
            tostring(from), #M.joinedList(), #dorm > 0 and string.format("; %d dormant local player(s) get no grid "
            .. "entry (%s)", #dorm, M.dormantText() or "") or "")
        return
    end
    local guests = localGuests()
    if #guests == 0 then return end
    if new == "LOADING" or not U.isServer() then
        U.warn(TAG, "race not launched by SWGRCouch (from %s): removing %d local guest(s)", tostring(from), #guests)
        local _, kept = M.removeAll("race not launched by SWGRCouch", "launch")
        if (kept or 0) > 0 then
            -- GuestRemoval "never": the guests stay; one view, and (server) their cars go to the AI once they exist
            St.race.singleView = true
            if U.isServer() then
                for _, sl in pairs(St.join.slots) do sl.abandonPending = true end   -- Lua table
            end
        end
        return
    end
    local gs = U.gs()
    local handed, removed, kept = 0, 0, 0
    for i = 1, #guests do
        local e = guests[i]
        U.try(TAG, function()
            local pc = e.pc
            if not U.ok(pc) then return end
            local racer = U.isVehicle(pc.Pawn)
            if not racer and U.ok(gs) then
                -- ARacingGameState:FindRacerIndexByPlayer(Object player) -> Int (-1 = not a racer)
                local okI, idx = pcall(function() return gs:FindRacerIndexByPlayer(pc.PlayerState) end)
                racer = okI and type(idx) == "number" and idx >= 0
            end
            local id = e.ctrlId
            if racer and type(id) == "number" then
                local s = St.join.slots[id]
                if not s then s = newSlot(id); St.join.slots[id] = s end
                s.leaving = true
                s.abandonPending = true
                abandonCar(s, pc)                       -- no car yet: raceTick retries
                handed = handed + 1
            elseif dropGuest(id, pc, "race not launched by SWGRCouch", "launch") then
                removed = removed + 1
            else
                -- GuestRemoval "never": kept un-joined; a car it may still get goes to the AI (raceTick)
                local s = (type(id) == "number") and St.join.slots[id] or nil
                if s then s.abandonPending = true end
                kept = kept + 1
            end
        end)
    end
    St.join.active = false
    St.join.keep = false
    if handed > 0 or kept > 0 then St.race.singleView = true end
    U.warn(TAG, "race not launched by SWGRCouch (from %s, first seen in %s): %d guest car(s) handed to the AI, %d "
        .. "guest(s) removed, %d kept", tostring(from), tostring(new), handed, removed, kept)
    St.emit("players")
end

-- Hot reload (Ctrl+F11): the joined ControllerIds survive in a UE4SS shared variable (strings only). Each token is
-- the id followed by flag letters: L = leaving, D = pad disconnected, A = our Disconnect override is on its car
-- (without A/D a reconnect after the reload would be "no change" and the AI would keep the car), N = not joined
-- (a guest of a race the mod did not launch, kept only until the next front end), X = abandoned (its car is the
-- AI's for good), P = abandonPending (car not handed yet). St.race.singleView (set by the race_enter guard) is kept
-- too: the reloaded state re-enters the race from BOOT, where the guard does not run.
function M.persistShared(put)
    local ids = {}
    for id, s in pairs(St.join.slots) do
        if s.joined or s.leaving or s.abandonPending then
            ids[#ids + 1] = tostring(id) .. (s.leaving and "L" or "") .. (s.disconnected and "D" or "")
                .. (s.aiOverride and "A" or "") .. (s.joined and "" or "N") .. (s.abandoned and "X" or "")
                .. (s.abandonPending and "P" or "")
        end
    end
    put("join.joined", table.concat(ids, ","))
    local S = Seat()
    if S then put("join.seats", S.encode()) end
    put("join.keep", St.join.keep == true)
    put("join.enabled", St.join.enabled == true)
    put("join.frozen", St.join.frozen == true)
    put("join.singleView", St.race.singleView == true)
    -- the dangling-listener count is per game PROCESS (header), not per Lua state; pad presence: the boot-time device
    -- hook events do not come again after a reload
    put("join.removedCount", tostring(life.removedCount))
    local pads = {}
    for uid, on in pairs(padHook) do pads[#pads + 1] = tostring(uid) .. (on and "+" or "-") end   -- Lua table
    put("join.pads", table.concat(pads, ","))
end

function M.restoreShared(get)
    local v = get("join.joined")
    if type(v) == "string" and v ~= "" then
        for tok in v:gmatch("[^,]+") do
            local idStr, flags = tok:match("^(%d+)(%a*)$")
            local id = tonumber(idStr)
            if id and id >= 1 and id <= maxGuestId() then
                local s = newSlot(id)
                s.joined = flags:find("N", 1, true) == nil
                s.leaving = flags:find("L", 1, true) ~= nil
                s.disconnected = flags:find("D", 1, true) ~= nil
                s.aiOverride = flags:find("A", 1, true) ~= nil
                s.abandoned = flags:find("X", 1, true) ~= nil
                s.abandonPending = flags:find("P", 1, true) ~= nil
                St.join.slots[id] = s
            end
        end
        U.log(TAG, "hot reload: joined guests restored: %s", v)
    end
    local S = Seat()
    local sv = get("join.seats")
    if S and type(sv) == "string" and sv ~= "" then
        local n = S.decode(sv)
        U.log(TAG, "hot reload: %d seat(s) restored: %s", n, sv)
    end
    if get("join.keep") == true then St.join.keep = true end
    if get("join.enabled") == true then St.join.enabled = true end
    if get("join.frozen") == true then St.join.frozen = true end
    local rc = tonumber(get("join.removedCount"))
    if rc and rc > 0 then
        life.removedCount = rc
        U.warn(TAG, "hot reload: %d guest RemovePlayer(s) earlier in this game session (V-JOIN-12)", rc)
    end
    local pads = get("join.pads")
    if type(pads) == "string" then
        for uidStr, sign in pads:gmatch("(%d+)([%+%-])") do padHook[tonumber(uidStr)] = (sign == "+") end
    end
    if get("join.singleView") == true then
        -- St.race is rebuilt by the first onNewWorld of the new state (St.resetRace): set it again on that first
        -- "world" event, before phase.tick emits "race_enter"/"phase" (split.enterRace, gfx, hud read it)
        local pendingSV = true
        St.on("world", TAG .. ".sv", function()
            if not pendingSV then return end
            pendingSV = false
            St.race.singleView = true
            U.log(TAG, "hot reload: single view restored (guests handed to the AI)")
        end)
    end
end

function M.init()
    St.join.slots = St.join.slots or {}
    if cfg.GuestRemoval ~= nil and cfg.GuestRemoval ~= "never" then
        if cfg.GuestRemovalUnsafe == true then
            U.err(TAG, "GuestRemoval=%s with GuestRemovalUnsafe: guests WILL be removed, and every RemovePlayer crashes "
                .. "the game at the next control-mapping rebuild (crash reproducer)", tostring(cfg.GuestRemoval))
        else
            U.err(TAG, "GuestRemoval=%s ignored: every RemovePlayer crashes the game at the next control-mapping "
                .. "rebuild (2026-10-06 crash); treated as \"never\" (set GuestRemovalUnsafe = true to reproduce)",
                tostring(cfg.GuestRemoval))
        end
    end
    U.hook(C.FN.DeviceChanged, { post = M.onDevice }, TAG)
    St.on("phase", TAG, function(new, old)
        if new == "FRONTEND" then M.resync() end
    end)
    St.on("race_enter", TAG, onRaceEnter)
end

return M
