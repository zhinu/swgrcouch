-- split.lua (G4 Players & launch) - engine split-screen settings, single-view control, 2P layout switch.
-- ARCHITECTURE.md §1.6 Layout, §4.2 `split`.
--
-- Engine data (verified with scripts/reflect-types.py --class UGameMapsSettings / reflect-enum.py):
--   UGameMapsSettings CDO (/Script/EngineSettings.Default__GameMapsSettings):
--     Bool bUseSplitscreen
--     Byte<ETwoPlayerSplitScreenType>  TwoPlayerSplitscreenLayout   Horizontal=0 (top/bottom), Vertical=1 (side by side)
--     Byte<EThreePlayerSplitScreenType> ThreePlayerSplitscreenLayout FavorTop=0
--     Enum<EFourPlayerSplitScreenType> FourPlayerSplitscreenLayout  Grid=0
--     Bool bOffsetPlayerGamepadIds
--   Bytes and enums are written as integers, bools as Lua booleans [API§8].
--   GameplayStatics:SetForceDisableSplitscreen(Object WorldContextObject, Bool bDisable)
--   GameplayStatics:IsSplitscreenForceDisabled(Object WorldContextObject) -> Bool

local C        = require("consts")
local settings = require("settings")
local St       = require("state")
local U        = require("util")
local sched    = require("sched")

local M = {}
local TAG = "split"

local RACE_PHASES = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }

local function gms()
    local g = U.GMS()
    if not U.ok(g) then
        U.logOnce("split.gms", TAG, "GameMapsSettings CDO not found; split-screen settings not applied")
        return nil
    end
    return g
end

local function layout2PValue()
    if settings.get("Layout2P") == "side-by-side" then return C.E.TwoP.Vertical end
    return C.E.TwoP.Horizontal
end

local function layout2PText()
    if settings.get("Layout2P") == "side-by-side" then return "SIDE BY SIDE" end
    return "TOP / BOTTOM"
end

-- Writes the layout part of the GameMapsSettings CDO. The viewport reads the CDO whenever it lays the
-- players out, so in a race the new layout is applied at once through relayout().
function M.applyLayoutSettings()
    local g = gms()
    if not g then return false end
    g.bUseSplitscreen = true
    g.TwoPlayerSplitscreenLayout = layout2PValue()
    g.ThreePlayerSplitscreenLayout = C.E.ThreeP.FavorTop
    g.FourPlayerSplitscreenLayout = C.E.FourP.Grid
    U.log(TAG, "GameMapsSettings: bUseSplitscreen=true, 2P=%s (%d), 3P=FavorTop, 4P=Grid",
        settings.get("Layout2P"), layout2PValue())
    -- VERIFY(V-SPL-02): a CDO write is picked up live (F8 in a 2P race flips the layout).
    if U.mod("phase").isRace() then M.relayout() end
    return true
end

-- KeyboardIsP1 -> bOffsetPlayerGamepadIds: pad k drives ControllerId k+1, P1 is keyboard only.
function M.applyGamepadOffset()
    local g = gms()
    if not g then return false end
    local on = (settings.get("KeyboardIsP1") == true)
    -- VERIFY(V-SPL-03): the offset is read at input-routing time (no restart needed).
    g.bOffsetPlayerGamepadIds = on
    U.log(TAG, "GameMapsSettings: bOffsetPlayerGamepadIds=%s", tostring(on))
    return true
end

-- on = true: one full-screen view whatever the number of local players.
function M.setSingleView(on)
    local world = U.world()
    if not U.ok(world) then return false end
    U.GS():SetForceDisableSplitscreen(world, on == true)
    U.dbg(TAG, "SetForceDisableSplitscreen(%s)", tostring(on == true))
    return true
end

function M.isSingleView()
    local world = U.world()
    if not U.ok(world) then return false end
    return U.GS():IsSplitscreenForceDisabled(world) == true
end

-- present.lua's layout decision for the current race-flow state: true = one full-screen view (intro, cinematics,
-- results), false = split, nil = present.lua off / no known state (the old behaviour: split).
local function presentWantsSingle()
    local ok, present = pcall(U.mod, "present")
    if not ok or type(present) ~= "table" or type(present.decide) ~= "function" then return nil end
    local cfg = require("config")
    if cfg.PresentViewMode == "split" then return nil end
    local okD, view = pcall(present.decide)
    if not okD or view == nil then return nil end
    return view == "single"
end

-- Listener: entering a race world. Split views come on (the engine lays them out from the CDO) - except while
-- present.lua wants the race-flow state on one view (LoadingPhase/intro): then the race starts on ONE view and
-- present.tick splits it at the ignition/countdown (no one-frame split at LOADING).
function M.enterRace()
    if St.race.singleView == true then
        -- join's "race_enter" guard handed the guests' cars to the AI (race not launched by the mod): one view
        M.setSingleView(true)
        St.race.localViews = 1
        U.log(TAG, "race: single view (guests handed to the AI)")
        return
    end
    St.race.localViews = #U.localPlayers()
    -- At LOADING the race-flow CSM assets are usually not in memory yet: presentWantsSingle() is nil (unknown). With
    -- PresentViewMode "auto" an unknown state counts as ONE view (the intro must not start split); present.viewTick
    -- splits at the ignition/countdown, or by its safety net once the race started.
    local want = presentWantsSingle()
    local auto = false
    pcall(function()
        local present = U.mod("present")
        auto = require("config").PresentViewMode ~= "split" and type(present) == "table"
            and type(present.decide) == "function"
    end)
    local single = (St.race.localViews > 1) and (want == true or (want == nil and auto))
    M.setSingleView(single)
    if St.race.localViews > 1 and auto then
        pcall(function()
            U.mod("present").noteView(single and "single" or "split",
                want == nil and "LOADING: race-flow state not known yet" or "LOADING")
        end)
    end
    -- VERIFY(V-SPL-01): 2 local players -> 2 views in the configured 2P layout (from the ignition/countdown on when
    -- present.lua runs the intro on one view).
    U.log(TAG, "race: %d local view(s), 2P layout %s, %s", St.race.localViews, layout2PText(),
        single and "ONE view until the race-flow splits it (present.lua)" or "split views on")
end

-- Listener: phase -> FRONTEND. One view while (dormant or joined) guests exist in the menus.
function M.enterFrontEnd()
    M.setSingleView(true)
end

-- Guests now live through the whole front-end visit, also on the game's own tabs (join.lua GUEST LIFECYCLE): the
-- front end must never show their views. Called by join (session closed / guests kept) and on every "players"
-- event; a write only when the flag is actually off, so it is cheap to call often.
function M.frontEndSingleView(why)
    if not U.mod("phase").isFrontEnd() then return false end
    local world = U.world()
    if not U.ok(world) then return false end
    if U.GS():IsSplitscreenForceDisabled(world) == true then return true end
    U.GS():SetForceDisableSplitscreen(world, true)
    U.log(TAG, "front end: split screen was not force-disabled (%s); one view restored", tostring(why))
    return true
end

-- Re-run the viewport layout: force-disable on, then off one frame later (a flip inside a single
-- frame might be coalesced by the viewport). Without EngineTick the 0 ms fallback would run on the next ProcessEvent,
-- normally in the same frame: sched.nextFrame then waits RELAYOUT_FALLBACK_MS (a few frames) instead.
-- VERIFY(V-SPL-02): F8 / the lobby layout row visibly changes the 2P layout in a race (also with EngineTick off).
local RELAYOUT_FALLBACK_MS = 50
function M.relayout()
    if not U.mod("phase").isRace() or St.race.singleView == true then return end
    M.setSingleView(true)
    sched.nextFrame("split", function()
        if not U.mod("phase").isRace() then return end
        -- present.lua keeps intro/cinematic/results phases on one view: do not split those
        local keepSingle = false
        pcall(function() keepSingle = U.mod("present").isSingleView() == true end)
        M.setSingleView(keepSingle)
    end, RELAYOUT_FALLBACK_MS)
end

-- F8 and the Lobby's layout row: flip the 2P layout, persist it, apply it live.
function M.toggle2PLayout()
    settings.cycle("Layout2P", { "top-bottom", "side-by-side" })
    M.applyLayoutSettings()
    St.emit("status", "2P LAYOUT: " .. layout2PText())
end

-- Runs on the game thread at boot (main: sched.run("boot", split.init)): CDO writes + phase listeners.
function M.init()
    M.applyLayoutSettings()
    M.applyGamepadOffset()
    St.on("phase", TAG, function(new, old)
        -- Any first race phase counts as "entering the race": the MAIN poll may skip LOADING when the
        -- grid already exists on its first look at the new world.
        if RACE_PHASES[new] and not RACE_PHASES[old] then
            M.enterRace()
        elseif new == "FRONTEND" then
            M.enterFrontEnd()
        end
    end)
    -- Results -> menu: one view from the moment the race is left. The force-disable flag lives on the game viewport
    -- client (it outlives the world), so the transition map and the front-end scene are not drawn once per guest
    -- (with arbitrary guest cameras) until phase.tick sees the front end. Emitted on the game thread (hook or poll).
    St.on("leaving", TAG, function()
        M.setSingleView(true)
    end)
    -- net's servertravel watchdog restored the race phase (phase.cancelLeaving): split views back, unless this race
    -- runs single-view by design (join's race_enter guard handed the guests to the AI).
    St.on("leaving_cancelled", TAG, function()
        local keepSingle = St.race.singleView == true
        if not keepSingle then pcall(function() keepSingle = U.mod("present").isSingleView() == true end) end
        M.setSingleView(keepSingle)
    end)
    -- guest set changed (join open/close/commit, a pad joined or left): in the front end, keep one view
    St.on("players", TAG, function()
        U.try(TAG, M.frontEndSingleView, "players")
    end)
end

return M
