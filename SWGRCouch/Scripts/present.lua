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
-- Race smoothness (2026-10-15: present.tick spikes in the countdown): a state asset NOT in memory was looked up again
-- on every call (raw StaticFindObject, ~2.5 ms in a race world), several per MAIN tick while decide() walks the rules
-- down to the pre-race states. A miss is now trusted for MISS_TTL_MS (per world), and at most MISS_FINDS_PER_TICK
-- earlier misses are looked up again per MAIN tick (the others wait: not in memory = inactive). A name never looked
-- up in this world is always looked up (no budget: a loaded state is never reported inactive by the budget).
local MISS_TTL_MS, MISS_FINDS_PER_TICK = 1000, 1
local assetCache, missAt, missWorld = {}, {}, nil
local findBudget = MISS_FINDS_PER_TICK
local function stateAsset(name)
    local o = assetCache[name]
    if o and U.ok(o) then return o end
    assetCache[name] = nil
    if missWorld ~= St.worldGen then missWorld, missAt = St.worldGen, {} end
    local at = missAt[name]
    if at then
        if St.nowMs() - at < MISS_TTL_MS or findBudget <= 0 then return nil end
        findBudget = findBudget - 1
    end
    local ok, f = pcall(StaticFindObject, rf(name))
    if ok and U.ok(f) then assetCache[name] = f; missAt[name] = nil; return f end
    missAt[name] = St.nowMs()
    return nil
end

-- true / false; nil when the manager is missing (unknown)
local function stateActive(name)
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    if not U.ok(mgr) then return nil end
    local a = stateAsset(name)
    if not a then return false end
    -- IsStateActiveByRef(Object) -> Bool, through the cached UFunction (couch-racegc: no wrapper per call)
    local ok, v = U.pcallFn(mgr, U.CSM_ACTIVE_FN or "", "IsStateActiveByRef", a)
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

---------------------------------------------------------------------------------------------------- outro duplicates
-- Same cause, the whole results-droid assembly (Jules 2026-10-14, every split mode: "the droid is doubled", then "the
-- disc still has a duplicate"): the outro plays LS_ResultDroid_Common once per local player (live: two
-- LevelSequenceActors 4.2 s apart in a 2P race) and EACH spawns its own droid (SkeletalMeshActor SK_Pistachio_01),
-- projector disc (StaticMeshActor SM_CIN_HandheldProjector_A_01), SpotLight, hologram FX (NiagaraActor), podium
-- hologram (BP_PodiumHolo_C) and CineCameraActor at the same spot, animated 4 s apart. POSTRACE: per class, the
-- runtime-spawned actors (age > 0: level / sequence templates report 0) are grouped by spot (+ mesh for the mesh
-- actors); the OLDEST of a group stays (the set already on screen, the same set for every class), the others are
-- hidden. This replaces the 0.13.0 podium-only pass (it kept the first NAME, i.e. a hologram of the other set).
local OUTRO_CLASSES = { "SkeletalMeshActor", "StaticMeshActor", "SpotLight", "NiagaraActor", "BP_PodiumHolo_C" }
                                         -- exact classes (U.className), never subclasses such as level meshes
-- COST: every FindAllOf walks the whole object array (several ms in a race world, ~30 ms live; Jules saw the stutters
-- of a 500 ms version live). So: three passes per results visit (the sequences spawn their sets ~4 s apart), at
-- POSTRACE + 3 / 8 / 14 s, then nothing; each pass is spread over the MAIN ticks, ONE walk per tick (2026-10-15: the
-- 6 walks of a pass in one tick made a ~100 ms present.tick hitch): the sequences, then one class per tick, then the
-- grouping. Ages read on a later tick are taken back to the sequences' tick (game time ~ our clock).
local OUTRO_PASSES_MS = { 3000, 8000, 14000 }
local outWorld, outKept, outHidden, outStart, outNext, outPass = nil, {}, 0, nil, 1, nil
local walkedThisTick = false                       -- one FindAllOf per MAIN tick for the whole POSTRACE work
local function outroDedupeTick()
    if cfg.PresentPodiumDedupe == false then return end
    local now = St.nowMs()
    if outWorld ~= St.worldGen then
        outWorld, outKept, outHidden, outStart, outNext, outPass = St.worldGen, {}, 0, now, 1, nil
    end
    if not outPass then
        local at = OUTRO_PASSES_MS[outNext]
        if not at or now - outStart < at then return end
        outNext = outNext + 1
        outPass = { step = 0, groups = {} }
    end
    local ps = outPass
    if ps.step == 0 then
        -- only what the result sequences spawned: no older than the oldest LS_ResultDroid* sequence actor (+1 s). Live
        -- 2026-10-14 the first version also hid level geometry (BP_GfnStaticMeshActor_C pipes placed twice in L_Husky_P2P).
        local seqAge = nil
        walkedThisTick = true
        for _, sa in ipairs(FindAllOf("LevelSequenceActor") or {}) do
            if U.ok(sa) then
                pcall(function()
                    local seq = sa.LevelSequenceAsset
                    if U.ok(seq) and U.objName(seq):find("^LS_ResultDroid") then
                        local age = tonumber(sa:GetGameTimeSinceCreation()) or 0
                        if seqAge == nil or age > seqAge then seqAge = age end
                    end
                end)
            end
        end
        if seqAge == nil then outPass = nil; return end
        ps.seqAge, ps.t0, ps.step = seqAge, now, 1
        return
    end
    local cls = OUTRO_CLASSES[ps.step]
    if cls then
        ps.step = ps.step + 1
        local late = (now - ps.t0) / 1000                -- seconds since the sequences' ages were read
        local groups = ps.groups
        walkedThisTick = true
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if U.ok(a) and U.className(a) == cls then
                pcall(function()
                    local age = tonumber(a:GetGameTimeSinceCreation()) or 0
                    if age <= 0 or age - late > ps.seqAge + 1 then return end
                    local mesh = ""
                    if cls == "SkeletalMeshActor" then
                        pcall(function() mesh = U.objName(a.SkeletalMeshComponent.SkeletalMesh) end)
                    elseif cls == "StaticMeshActor" then
                        pcall(function() mesh = U.objName(a.StaticMeshComponent.StaticMesh) end)
                    end
                    local l = a:K2_GetActorLocation()
                    if math.abs(l.X) + math.abs(l.Y) + math.abs(l.Z) < 1 then return end
                    local k = string.format("%s/%s@%d:%d:%d", U.className(a), mesh, math.floor(l.X / 10),
                        math.floor(l.Y / 10), math.floor(l.Z / 10))
                    groups[k] = groups[k] or {}
                    table.insert(groups[k], { a = a, name = U.objName(a), age = age })
                end)
            end
        end
        return
    end
    outPass = nil
    for k, g in pairs(ps.groups) do
        local live = {}
        for _, x in ipairs(g) do if U.ok(x.a) then live[#live + 1] = x end end
        g = live
        if #g > 1 then
            local kept = outKept[k]
            table.sort(g, function(x, y)
                if x.name == kept then return true elseif y.name == kept then return false end
                return x.age > y.age                 -- oldest first
            end)
            outKept[k] = g[1].name
            for i = 2, #g do
                local hid = false
                pcall(function() hid = g[i].a.bHidden == true end)
                if not hid then
                    pcall(function() g[i].a:SetActorHiddenInGame(true) end)
                    outHidden = outHidden + 1
                    U.log(TAG, "outro duplicate %s hidden: %d at this spot (%s), %s kept (V-PRE-POD)", g[i].name, #g,
                        k:match("^[^@]+") or "?", g[1].name)
                end
            end
            -- a copy the older pass hid in THIS set is shown again (the kept one is the oldest now)
            local hid1 = false
            pcall(function() hid1 = g[1].a.bHidden == true end)
            if hid1 then pcall(function() g[1].a:SetActorHiddenInGame(false) end) end
        end
    end
end

-- 0.13.0 (Jules: "FINISHED · You came 4th" on the full-screen outro, P1 had won): in the one full-screen view of the
-- post-race phase every player's WBP_Hud_Race_C is still in the viewport, stacked: the last one (P4's) covers P1's.
-- POSTRACE + one view: the guests' race HUDs go transparent (render opacity 0; the race is over, nothing restores them).
-- COST (race smoothness 2026-10-15): the FindAllOf ran every MAIN tick of the full-screen outro (present.tick spikes
-- all through POSTRACE). The guests' HUDs are all there when the outro starts and nothing shows them again, so: a few
-- passes per world, at HUD_PASSES_MS after the one view is first seen in POSTRACE, then nothing.
local HUD_PASSES_MS = { 0, 1000, 3000, 8000 }
local hudWorld = nil
local hudPassWorld, hudPassStart, hudPassNext = nil, nil, 1
local function guestHudTick()
    if cfg.PresentOutroP1Hud == false or not M.isSingleView() or walkedThisTick then return end
    local now = St.nowMs()
    if hudPassWorld ~= St.worldGen then hudPassWorld, hudPassStart, hudPassNext = St.worldGen, now, 1 end
    local at = HUD_PASSES_MS[hudPassNext]
    if not at or now - hudPassStart < at then return end
    hudPassNext = hudPassNext + 1
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

-- couch-fix64 (AUTO-158e, live round 9 FM12 11:56:46-50, shot fm3-results: P2 wrecked, P1 won, and the post-race camera
-- showed a full-screen "WRECKED"). Not the mod's plate (finishplate removed its plates at POSTRACE): the game's outro,
-- WBP_PostRace_Info, is created by the UIManager for the LAST local PC (= P2) and its Construct reads its OWNER's
-- RaceEventComponent (ux-split-inventory: "position text = P2's while the flow is P1's"; couchsolo #35: its title =
-- the owner's verdict, InitForWrecked). So it was P2's WRECKED, drawn over P1's one full-screen view. In the one view
-- of POSTRACE a guest-owned outro goes transparent like the guests' HUDs (P1's own HUD outro shows his place); a
-- race-alone couch test keeps it (couchsolo writes P1's own result into it), so does a boss race raced as copies
-- (instances.lua writes P1's own place into it). Pure decision for the tests:
function M.outroInfoAction(ownerIsP1, singleView, raceAlone)
    if not singleView or ownerIsP1 or raceAlone then return nil end
    return "hide"
end

local infoHidden = {}
local INFO_EVERY_MS, INFO_FOR_MS = 250, 12000          -- UIManager layer reads (no walk) for the outro's first 12 s
function M.outroInfoPass(p1)
    if cfg.PresentOutroP1Hud == false or not M.isSingleView() then return end
    local now = St.nowMs()
    if infoHidden.gen ~= St.worldGen then infoHidden = { gen = St.worldGen, n = 0, start = now, at = -1e12 } end
    if now - infoHidden.start > INFO_FOR_MS or now - infoHidden.at < INFO_EVERY_MS then return end
    infoHidden.at = now
    local alone = false
    pcall(function() alone = U.mod("couchsolo").raceAlone() == true end)
    -- a boss race raced as copies: instances.lua writes P1's own place into this outro (couch-fix49)
    pcall(function() if U.mod("instances").bossRace() == true then alone = true end end)
    if alone then return end
    local w = nil
    pcall(function() w = U.mod("hud").postRaceInfo() end)
    if not U.ok(w) then return end
    do
        pcall(function()
            if not w:IsInViewport() then return end
            local own = w:GetOwningPlayer()
            local isP1 = U.ok(own) and U.key(own) == U.key(p1)
            if M.outroInfoAction(isP1, M.isSingleView(), alone) ~= "hide" then return end
            if (tonumber(w:GetRenderOpacity()) or 1) <= 0 then return end
            w:SetRenderOpacity(0.0)
            infoHidden.n = infoHidden.n + 1
            if infoHidden.n == 1 then
                local pn = "?"
                pcall(function() pn = tostring(U.mod("join").pnumForPC(own) or "?") end)
                U.log(TAG, "outro: the game's WBP_PostRace_Info belongs to P%s (the UIManager's last local PC) and reads "
                    .. "HIS result: hidden in P1's full-screen view, P1's own HUD outro shows (AUTO-158e)", pn)
            end
        end)
    end
end

---------------------------------------------------------------------------------------------------- loop
-- MAIN loop, race phases (main.lua calls present.tick() right before hud.tick(); cfg.PresentFromMain = true).
function M.tick()
    if not RACE_PHASES[St.phase] then return end
    if St.race.singleView == true then return end -- join's race_enter guard: one view by design (split.lua)
    local lps = U.localPlayers()
    if #lps < 2 then return end
    findBudget, walkedThisTick = MISS_FINDS_PER_TICK, false
    U.try(TAG, viewTick)
    if St.phase == "POSTRACE" then
        U.try(TAG, outroDedupeTick); U.try(TAG, guestHudTick)
        local p1 = U.p1()
        if U.ok(p1) then U.try(TAG, M.outroInfoPass, p1) end
    end
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
