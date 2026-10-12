-- present.lua (G5, added 2026-10-07 after session B): per-phase view layout and per-player pre-race screens.
--   1. VIEW MODE. Intro / cinematic / results phases run as ONE full-screen view (P1's view, which is the one the
--      game's cinematics drive); the views split when racing control starts (ignition or countdown).
--      User feedback 4: "Race introduction video was on top screen only should be full screen".
--   2. IGNITION / PRE-FLIGHT CHECKS (feedback 3: "keys to press at specific order, only for top player"; session E:
--      "the screens don't respond to gamepads"): ignition.lua + ignpad.lua (since 2026-10-07 session E), ticked from
--      here; cfg.IgnitionMode "auto" | "perplayer" | "simple" | "p1game_guestauto" | "complete" | "off".
-- Poll-based only (MAIN loop, 250 ms): Blueprint-function hooks never fire in this build.
--
-- Static facts (2026-10-07; decoded with tools/cue4cli + work/usmap, jmap = work/runtime/*.jmap, disassembly with
-- scripts/kismet-disasm.py of retoc legacy copies; notes/research/presentation.md has the full trail):
--   Race-flow CSM (RaceCsmAsset.RaceGameModeState = ESimpleRaceGameModeState):
--     LoadingPhase{WaitForPlayersToArrive, WaitForLevelToLoad (WBP_PlanetIntro_Title@Menu), WaitForIntroMovieToFinish}
--     PreRacePhase{IntroSequence{DisplayIntroSequenceScreen (WBP_PreRace_Info@HUD)}}          <- track intro
--     InRacePhase{PrepareForEventStart (WBP_PreRace_Info@HUD, grid intro), SideBet{SideBet_UI@Menu, GraceTime},
--                 IgnitionSequence (WBP_IgnitionScreen@HUD), Countdown{Countdown_InHud, _Paused},
--                 Racing{InProgress, LocalResults, Spectating}, RollingStart, RollingRestart}
--     IntermissionPhase{..., Intermission_Cinematic}, PostRacePhase{Outro, Results, RollingOutro, ...}
--   CosmeticStateMachineManager:IsStateActiveByRef(Object) -> Bool (true for an active parent of the current state:
--     session B diag read CSM_PostRace=true while in a child state).
--   GameplayStatics:SetForceDisableSplitscreen(World, Bool) through split.setSingleView(on).
--   WBP_IgnitionScreen_C (UIManager HUD layer, viewport-wide): preflight list from GetOwningPlayer()->PlayerState->
--     PreFlightCheckComponent (per player), but ignition phase/status from GetPlayerPawn(self, 0) (P1's car) at
--     Construct; vars VehiclePawn (VehiclePawn), IgnitionPhase (EIgnitionPhase), PreFlightCheckLists (Array),
--     "Pre Flight Check Component"; BP functions SetupIgnitionBindings(), AddPreflightChecksToList(),
--     OnSimplePreflightChanged(), OnIgnitionPhaseChanged(OldPhase, NewPhase), "On Ignition Status Changed"(Old, New).
--   Input of the checks is NOT in the widget: BP_GfnPlayerController (every PC, guests included) binds the
--     IA_Veh_* actions and calls its pawn's PlayerState.PreFlightCheckComponent:TestPreflightCheckInput(IA).
--   PlayerPreFlightCheckComponent: bAreChecksUnderway (Bool), bUseSimplePreflights (Bool), AfterburnerCheck
--     (PreFlightCheck), PreFlightChecksByAction (Map<SoftObject<InputAction>, PreFlightCheck>),
--     Server_OnSuccessfulPreFlightCheck(PreFlightCheck, Bool autoComplete) (server RPC).
--   AVehiclePawn.VehicleState (UVehicleState): IgnitionPhase (EIgnitionPhase Offline=0 EngineIgnite=1 PerfectStart=2
--     PostPerfectStart=3), IgnitionStatus (EIgnitionStatus Off=0 AlreadyOn=1 SuccessfulIgnite=2 FailedIgnite=3).

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "present"

local RF = "/Game/Griffin/Config/StateMachines/RaceFlow/"
local function rf(n) return RF .. n .. "." .. n end

-- Order matters: the first active entry decides. PostRacePhase first (its children may outlive Racing for a frame),
-- then the split states, then the single ones. "ignition" is resolved through cfg.IgnitionView.
local VIEW_RULES = {
    { name = "CSM_RF_PostRacePhase",        view = "single" },
    { name = "CSM_RF_IntermissionPhase",    view = "single" },
    -- P1 out while the race goes on (wreck.lua keeps an offline race running until every local human is out): P1's
    -- CSM shows its spectate / local-results states, the guests still race in their own views. They are children of
    -- CSM_RF_Racing (split anyway); listed so a state reached outside it (mid-game-join path) cannot fall through to a
    -- single view. hud.lua keeps their full-screen widgets off the guests' views (manageSpectateWidget /
    -- manageLocalResults). VERIFY(V-WD-11): "view: SPLIT" stays while P1 spectates.
    { name = "CSM_RF_SpectatingInProgress", view = "split" },
    { name = "CSM_RF_Spectating",           view = "split" },
    { name = "CSM_RF_LocalResults",         view = "split" },
    { name = "CSM_RF_Racing",               view = "split" },
    { name = "CSM_RF_Countdown",            view = "split" },
    { name = "CSM_RF_IgnitionSequence",     view = "ignition" },
    { name = "CSM_RF_RollingStart",         view = "split" },
    { name = "CSM_RF_RollingRestart",       view = "split" },
    { name = "CSM_RF_SideBet",              view = "single" },
    { name = "CSM_RF_PrepareForEventStart", view = "single" },
    { name = "CSM_RF_PreRacePhase",         view = "single" },
    { name = "CSM_RF_LoadingPhase",         view = "single" },
}
local RACE_PHASES = { LOADING = true, PRERACE = true, RACING = true, POSTRACE = true }

local function P()
    St.present = St.present or { view = nil, why = nil, ign = { players = {} } }
    St.present.ign = St.present.ign or { players = {} }
    return St.present
end

local function lazy(name)
    local ok, m = pcall(U.mod, name)
    if ok and type(m) == "table" then return m end
    return nil
end

---------------------------------------------------------------------------------------------------- CSM queries
-- Find-only (never LoadAsset from the MAIN poll): a state asset that is not in memory cannot be active.
local assetCache = {}
local function stateAsset(name)
    local o = assetCache[name]
    if o and U.ok(o) then return o end
    local ok, f = pcall(StaticFindObject, rf(name))
    if ok and U.ok(f) then assetCache[name] = f; return f end
    assetCache[name] = nil
    return nil
end

-- true / false; nil when the manager is missing (unknown)
local function stateActive(name)
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    if not U.ok(mgr) then return nil end
    local a = stateAsset(name)
    if not a then return false end
    local ok, v = pcall(function() return mgr:IsStateActiveByRef(a) end) -- IsStateActiveByRef(Object) -> Bool
    if ok and type(v) == "boolean" then return v end
    return nil
end
M.stateActive = stateActive

---------------------------------------------------------------------------------------------------- view mode
local function ignitionMode()
    local ig = lazy("ignition")
    if ig and ig.mode then return ig.mode() end
    return tostring(cfg.IgnitionMode)
end

local function ignitionView()
    local v = cfg.IgnitionView
    if v == "split" or v == "single" then return v end
    return "split" -- every mode shows each player its own checks / engine-start prompt
end
M.ignitionView = ignitionView

-- "single" | "split" | nil (no known race-flow state active), plus the deciding state's name.
function M.decide()
    for _, r in ipairs(VIEW_RULES) do
        if stateActive(r.name) == true then
            local v = r.view
            if v == "ignition" then v = ignitionView() end
            return v, r.name
        end
    end
    return nil, nil
end

-- Is the race running on ONE view right now (our decision, or the engine flag when we have none)?
function M.isSingleView()
    local p = P()
    if p.view ~= nil then return p.view == "single" end
    return St.race.singleView == true
end

local function viewMode()
    local m = cfg.PresentViewMode
    if m == "auto" or m == "split" then return m end
    return "auto"
end

local function applyView(view, why)
    local p = P()
    local split = lazy("split")
    if not split then return end
    local wantSingle = (view == "single")
    local okE, isSingle = pcall(split.isSingleView)
    if okE and isSingle == wantSingle and p.view == view then return end
    -- VERIFY(V-PRE-01): SetForceDisableSplitscreen(true) mid-race shows P1's view (the cinematic) full screen and
    -- (false) gives every local player its view back with its own camera, without a hitch the players notice.
    if not (okE and isSingle == wantSingle) then U.try(TAG, split.setSingleView, wantSingle) end
    if p.view ~= view then
        U.log(TAG, "view: %s (%s)", wantSingle and "ONE FULL-SCREEN VIEW" or "SPLIT", tostring(why))
        local gfx = lazy("gfx")
        if gfx and gfx.onViewModeChanged then U.try(TAG, gfx.onViewModeChanged, wantSingle) end
    end
    p.view, p.why = view, why
end

local function viewTick()
    if viewMode() ~= "auto" then return end
    local view, why = M.decide()
    if view == nil then
        -- between states / unknown: keep the last layout (no flapping). Safety net: split.enterRace starts the race
        -- on ONE view while no race-flow state is known yet; if no state ever resolves (CSM lookup broken), the
        -- race must not stay on one view once it runs.
        if St.race.started == true and P().view == "single" then
            applyView("split", "safety net: race started, no known race-flow state")
        end
        return
    end
    applyView(view, why)
end

-- split.enterRace (LOADING) started the race on one view before any race-flow state was known: record it as our
-- decision (and tell gfx), so viewTick's safety net and isSingleView see it.
function M.noteView(view, why)
    local p = P()
    if p.view ~= view then
        U.log(TAG, "view: %s (%s)", view == "single" and "ONE FULL-SCREEN VIEW" or "SPLIT", tostring(why))
        local gfx = lazy("gfx")
        if gfx and gfx.onViewModeChanged then U.try(TAG, gfx.onViewModeChanged, view == "single") end
    end
    p.view, p.why = view, why
end

---------------------------------------------------------------------------------------------------- ignition
-- Moved to ignition.lua (+ ignpad.lua: each player's own pad, pad prompts) on 2026-10-07 after session E; the
-- state stays in St.present.ign (diag.lua).
local function ignitionMod() return lazy("ignition") end

function M.clearIgnition()
    local ig = ignitionMod()
    if ig then U.try(TAG, ig.clear) end
end

---------------------------------------------------------------------------------------------------- podium hologram
-- 0.13.0 (Jules 2026-10-12: "in the hologram of the race finish screens, three characters get multiplied"): the race
-- outro spawns one BP_PodiumHolo_C per local player, all at the same spot (live: 4 at one location in a 4-player race,
-- plus the class template at the origin), so the podium figures overlap 4 times. POSTRACE: of the holograms at one
-- location the first (by name) stays, the others are hidden (SetActorHiddenInGame). Find-only, throttled.
local holoMs, holoWorld, holoHidden, holoKept = -1e12, nil, 0, {}
local function podiumTick()
    if cfg.PresentPodiumDedupe == false then return end
    local now = St.nowMs()
    if now - holoMs < 500 then return end
    holoMs = now
    if holoWorld ~= St.worldGen then holoWorld, holoHidden, holoKept = St.worldGen, 0, {} end
    local all = FindAllOf("BP_PodiumHolo_C")
    if not all then return end
    local groups = {}
    for _, a in ipairs(all) do
        pcall(function()
            if not U.ok(a) then return end
            local l = a:K2_GetActorLocation()
            if math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) < 1 then return end      -- the template at the origin
            local k = string.format("%d:%d:%d", math.floor(l.X / 10), math.floor(l.Y / 10), math.floor(l.Z / 10))
            groups[k] = groups[k] or {}
            table.insert(groups[k], { a = a, name = a:GetFName():ToString() })
        end)
    end
    for k, g in pairs(groups) do
        if #g > 1 then
            -- the first one seen at this spot stays (they spawn one by one: never hide the one already shown)
            local kept = holoKept[k]
            table.sort(g, function(x, y)
                if x.name == kept then return true elseif y.name == kept then return false end
                return x.name < y.name
            end)
            holoKept[k] = g[1].name
            for i = 2, #g do
                local hid = false
                pcall(function() hid = g[i].a.bHidden == true end)
                if not hid then
                    pcall(function() g[i].a:SetActorHiddenInGame(true) end)
                    holoHidden = holoHidden + 1
                    U.log(TAG, "podium hologram %s hidden: %d at this spot, %s kept (V-PRE-POD)", g[i].name, #g, g[1].name)
                end
            end
        end
    end
end

-- 0.13.0 (Jules: "FINISHED · You came 4th" on the full-screen outro, P1 had won): in the one full-screen view of the
-- post-race phase every player's WBP_Hud_Race_C is still in the viewport, stacked: the last one (P4's) covers P1's.
-- POSTRACE + one view: the guests' race HUDs go transparent (render opacity 0; the race is over, nothing restores them).
local hudWorld = nil
local function guestHudTick()
    if cfg.PresentOutroP1Hud == false or not M.isSingleView() then return end
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local n = 0
    for _, w in ipairs(FindAllOf("WBP_Hud_Race_C") or {}) do
        pcall(function()
            if not (U.ok(w) and w:IsInViewport()) then return end
            local own = w:GetOwningPlayer()
            if U.ok(own) and U.key(own) ~= U.key(p1) and (tonumber(w:GetRenderOpacity()) or 1) > 0 then
                w:SetRenderOpacity(0.0)
                n = n + 1
            end
        end)
    end
    if n > 0 and hudWorld ~= St.worldGen then
        hudWorld = St.worldGen
        U.log(TAG, "outro: %d guest race HUD(s) hidden in the full-screen view: P1's place shows (V-PRE-OUT)", n)
    end
end

---------------------------------------------------------------------------------------------------- loop
-- MAIN loop, race phases (main.lua calls present.tick() right before hud.tick(); cfg.PresentFromMain = true).
function M.tick()
    if not RACE_PHASES[St.phase] then return end
    if St.race.singleView == true then return end -- join's race_enter guard: one view by design (split.lua)
    local lps = U.localPlayers()
    if #lps < 2 then return end
    U.try(TAG, viewTick)
    if St.phase == "POSTRACE" then U.try(TAG, podiumTick); U.try(TAG, guestHudTick) end
    local ig = ignitionMod()
    if ig then U.try(TAG, ig.tick, lps) end
end

-- FAST loop (main.lua, race phases): ignition.fastTick polls each player's pad while the ignition runs (ignpad) and
-- re-syncs a guest copy that could not be detached from P1's car; a no-op outside the ignition sequence.
function M.fastTick()
    if not RACE_PHASES[St.phase] then return end
    local ig = ignitionMod()
    if ig then U.tryEvery("present.ignfast", 5000, TAG, ig.fastTick) end
end

function M.clear()
    M.clearIgnition()
    local p = P()
    p.view, p.why = nil, nil
    p.ign = { players = {} }
end

local inited = false
function M.init()
    if inited then return end                      -- main.lua (cfg.PresentFromMain) or hud.lua's fallback, once
    inited, M._inited = true, true
    P()
    St.on("leaving", TAG, function() M.clear() end)
    St.on("phase", TAG, function(new)
        if not RACE_PHASES[new] or new == "LOADING" then M.clear() end
    end)
    U.log(TAG, "init: view=%s ignition=%s (view %s, simple %s, pad assist %s, prompts %s)", viewMode(),
        ignitionMode(), ignitionView(), tostring(cfg.IgnitionSimple == true), tostring(cfg.IgnitionPadAssist or "auto"),
        tostring(cfg.IgnitionPadPrompts or "pads"))
end

return M
