-- vpreview.lua (0.7.2, 2026-10-07; 0.10.0 RACERS step, 2026-10-09): a live 3D render of each RACE SETUP vehicle pick
-- ("photo bays"), front end only.
-- Design: notes/research/vehicle-preview.md (§3 design, §4 recipe, §6 risks, §7 VERIFY V-VP-01..07); 0.10.0:
-- notes/design/vehicle-step-v2.md §5.8 + RC-12 (keys per pad, modes, budgets, stats; VERIFY V-RC-10, V-RC-17).
-- setup.lua drives it (no init, no loop of its own): want() and brush() from renderColumns (classic flow) or from
-- racers.lua's view models (cards flow, + setMode()), tick() from its FAST pollNav while the VEHICLES / RACERS step
-- shows, release()/releaseAll() when a player goes, the step is left, the setup closes or the menu is replaced. No
-- hooks, no FindAllOf, no soft pointers: every call below is a reflected UFunction / property
-- (work/runtime/UE4SS_ObjectDump.txt, signatures checked 2026-10-07).
--
-- One bay per key, in the empty sky above the front-end sets (SetupPreviewX/Y/Z + (key - 1) * Spacing). Keys: the
-- classic columns pass their column (1..4), the RACERS cards ControllerId + 1 (1..4): a bay belongs to one pad and is
-- never handed to another player when someone leaves. Per bay:
--   * the model: GfnGameInstance.StaticVehicleClass (BP_StaticVehicleBase_C, an ACstStaticVehicle) spawned deferred
--     with `preset` = the pick's PRE_* class: the game's own SpawnFrontEndVehicle path, the spawn builds the model.
--     A new pick (after SetupPreviewDebounceMs) spawns a fresh actor (SetupPreviewRebuild "respawn": the unit count
--     restarts at 0, so "built" is unambiguous) or rewrites `preset` + UpdateCustomisationMesh() ("update", V-VP-02);
--   * the camera: an engine SceneCapture2D (show-only list = the model; bCaptureEveryFrame off, CaptureScene() from
--     this module only, so nothing keeps rendering after a reload) into a TextureRenderTarget2D. RGBA16f: a float
--     target gets display gamma 1, the tonemapper writes linear colour and the UI shows the right gamma;
--   * an optional fill PointLight beside the camera (SetupPreviewFillLux at the model, no shadows, Movable).
-- "Built" = CustomisationComponent:GetUnitContainerCount() > 0 and the yaw-0 bounds equal on two samples 100 ms
-- apart; then the camera is framed from the bounds and the show-only list and the framing are refreshed for 2.5 s
-- (late parts). Modes (setMode, per key; default "spin", the classic columns never set one):
--   * "spin": the model turns about its bounds centre (SetupPreviewSpinDps) and is captured every
--     SetupPreviewCaptureMs (spin 0: at ready, +0.5 s, +2 s, +5 s, then every 5 s);
--   * "still": the model stays at SetupPreviewYaw and is captured in bursts of SetupPreviewStillBurst: at ready, once
--     the late-part window is over, on a change to "still" and on recapture() (page shown again); then never until
--     the pick changes. A burst, not one capture: Lumen GI / reflections, TSR and eye adaptation accumulate over
--     captures (bAlwaysPersistRenderingState), so one capture looks noisier and darker than the turntable (RC-12).
-- Budgets over all bays: at most SetupPreviewCaptureBudget CaptureScene() per tick (the due bay captured longest ago
-- first: round robin), and at most one new pick built (spawn or in-place rebuild) per SetupPreviewSpawnGapMs (the
-- oldest waiting pick first). stats() counts captures (per second over 10 s), spawns and bays per mode (V-RC-17).
-- A card shows its render only once a capture of the applied pick has landed (2D card / previous render dimmed until).
-- Column image: a scene capture's FinalColorLDR alpha is not 1, so the raw target in a UImage can be invisible: the
-- target goes through an MID of an OPAQUE UI material (SetupPreviewMaterial, texture parameter
-- SetupPreviewMaterialParam). Default M_UI_RetainerBox_ScreenSpace, the only opaque UI material of the game with a
-- texture parameter (it adds the game's diegetic-screen look: warp lines, radial mask, twinkle; decoded 2026-10-07).
-- Live A/B alternatives: "/VirtualCamera/WidgetLibrary/VCamTakesBrowser/Widgets/mat/M_ThumbnailMask.M_ThumbnailMask"
-- with parameter "Target" (Epic's VCam thumbnail: rounded corners, AlphaComposite), or SetupPreviewBrush = "texture".
-- Failures: a model that cannot be built leaves its column on the 2D card (reason logged once per model); a
-- structural failure (CDO/class missing, spawn / target / material / preset write refused) turns the module off for
-- the session ("broken", logged once) and every column shows the 2D card.
-- Lifetime: actors live only in the front-end world they were spawned in; destroyed (K2_DestroyActor, game thread)
-- on release; a new world only drops the references (they die with it). The target (outer = GameInstance) and the
-- MID (transient) never reference a world. Hot reload: the actor paths are kept in the UE4SS shared variable
-- SWGRCouch.vpreview.actors whenever they change; the next Lua state destroys them on its first game-thread tick
-- (persistShared/restoreShared also exist, for main.lua's PERSIST_MODULES).
--
-- 0.12.0 UI v2 (notes/design/ui-v2/ui-redesign-final.md §10, VERIFY V-FIN-05): the backdrop goes INTO the capture (no
-- shipped UI material turns a capture's alpha into opacity, ui-parts-catalogue.md §4.7). cfg.PreviewBackdrop picks a
-- rung of the ladder; cfg.UiStyle "classic" always takes "cutout". Per bay, built with the capture (apply), placed by
-- frame() from the bounds:
--   * "studio": a back plane (StaticMeshActor + /Engine/BasicShapes/Plane, MID of the unlit
--     MI_Widget3DPassThroughUnlit_Masked_OneSided: SlateUI T_UI_SolidFill_Cmn, TintColorAndOpacity / BackColor STUDIO
--     x PreviewStudioGain) square to the camera axis, 2 x the bounds radius behind the model, 1.2 x the frustum there;
--     a floor plane (MID of /Engine/BasicShapes/BasicShapeMaterial, Color #B9B4AB, lit by the front-end sun: the
--     contact shadow) 2 uu under the bounds, 4 x the radius (PreviewStudioFloor = false drops it, V-FIN-14). The
--     capture's exposure is forced "fixed" (SetupPreviewEV) and its vignette off. Once per bay, after CALIB_CAPS
--     captures, the target's top-left corner is read back (KismetRenderingLibrary.ReadRenderTargetPixel) and logged
--     against #E3DFD6 +- 8 with a PreviewStudioGain suggestion (calibrate() re-arms it after a live config change);
--   * "scenario": the back plane only, SlateUI T_UI_Scenario_Bg, tint WHITE; exposure as configured, vignette off;
--   * "cutout": no plane: today's capture exactly (the v2 card shows the class cut-out on STUDIO: backdrop()).
-- The planes are movable, collision-free, shadow-free, drawn by scene captures only, in the show-only list and never
-- turned (the turntable spins the model only); they die with the bay (release / releaseAll; shared variable for a hot
-- reload). A plane that cannot be built drops its rung for the session (one WARN) and the next rung is built at once.
-- brush(): while a new pick builds, a studio / scenario bay reports kind "building" (dim 1: the card washes the last
-- frame, PAGE / BAND @0.43) instead of today's 0.5 dim; cutout keeps today's values.

local C     = require("consts")
local cfg   = require("config")
local sched = require("sched")
local St    = require("state")
local U     = require("util")
local V     = require("vehicles")

local M = {}
local TAG = "vpreview"

local KRL        = "/Script/Engine.Default__KismetRenderingLibrary"
local KML        = "/Script/Engine.Default__KismetMaterialLibrary"
local RBMAT      = "/Game/Griffin/UI/Library/Materials/Diegetic/M_UI_RetainerBox_ScreenSpace.M_UI_RetainerBox_ScreenSpace"
local VEH_BP     = "/Game/Griffin/Vehicles/BP_StaticVehicleBase.BP_StaticVehicleBase_C"
local VEH_NATIVE = "/Script/Griffin.CstStaticVehicle"
local CAPTURE    = "/Script/Engine.SceneCapture2D"
local LIGHT      = "/Script/Engine.PointLight"
local PRIMITIVE  = "/Script/Engine.PrimitiveComponent"
local SPAWN_ALWAYS, SCALE_MULTIPLY = 1, 1   -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn, ESpawnActorScaleMethod
local MOVABLE, CANDELAS = 2, 1              -- EComponentMobility::Movable, ELightUnits::Candelas
local MID_TRANSIENT = 1                     -- EMIDCreationFlags::Transient (outer = the transient package)
local SHARED = "vpreview.actors"            -- shared variable C.MOD .. "." .. SHARED (main.lua's naming)
local SETTLE_MS, SAMPLE_MS, LATE_MS = 300, 100, 2500
local STATIC_CAPS = { 0, 500, 2000, 5000 }  -- ms after ready when the model does not spin
local CAPS_WINDOW_MS = 10000                -- stats().capturesPerSec: captures of this window
local CAPTURE_SLACK_MS = 10                 -- FAST ticks come a few ms early or late: without this slack a 66 ms cap at
                                            --   33 ms ticks waits a third tick half of the time (~12 instead of 15/s)
local DIM = 0.5                             -- alpha of the previous model's render while the new pick builds
local ZERO_ROT = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
-- 0.12.0 backdrop (§10). Paths: the spec's and notes/asset-list.txt (engine BasicShapes in pakchunk0).
local MESH_ACTOR = "/Script/Engine.StaticMeshActor"
local PLANE_MESH = "/Engine/BasicShapes/Plane.Plane"       -- 100 x 100 uu, centred, normal +Z, BlockAll (decoded)
local UNLIT_MAT  = "/Game/Griffin/UI/Library/Materials/Diegetic/MI_Widget3DPassThroughUnlit_Masked_OneSided."
                   .. "MI_Widget3DPassThroughUnlit_Masked_OneSided"   -- Masked unlit; SlateUI, TintColorAndOpacity, BackColor
local FLOOR_MAT  = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"                  -- lit; Color, Roughness
local FILL_TEX   = "/Game/Griffin/UI/Library/Textures/Common/T_UI_SolidFill_Cmn.T_UI_SolidFill_Cmn"        -- 32 px white
local SCEN_TEX   = "/Game/Griffin/UI/Library/Textures/Backgrounds/T_UI_Scenario_Bg.T_UI_Scenario_Bg"      -- teal #1E353F
local NO_COLLISION = 0                      -- ECollisionEnabled::NoCollision
local BEHIND, COVER = 2, 1.2                -- back plane: x bounds radius behind the centre, x the frustum at its depth
local FLOOR_SIZE, FLOOR_GAP = 4, 2          -- floor: x bounds radius, uu under the bounds
local CALIB_CAPS = 6                        -- captures of a ready model before the corner read (TSR / Lumen settled)
local CALIB_TOL = 8                         -- §10: #E3DFD6 +- 8 per sRGB channel
local STUDIO_SRGB = { 227, 223, 214 }       -- #E3DFD6 (theme STUDIO)
local STUDIO_LIN  = { 0.7682, 0.7379, 0.6724 }
local FLOOR_LIN   = { 0.4851, 0.4564, 0.4072 }   -- #B9B4AB

local function opt(name, default)
    local v = cfg[name]
    if v == nil then return default end
    return v
end

local function num(name, default)
    local n = tonumber(opt(name, default))
    if n == nil or n ~= n then return default end
    return n
end

local function int(name, default) return math.floor(num(name, default) + 0.5) end

local bays = {}            -- [key] = bay (see newBay); key = classic column or RACERS ControllerId + 1
local modes = {}           -- [key] = "spin" | "still" (setMode; nil = "spin"); dropped with the bay
local broken = nil         -- session-wide reason: 2D cards only
local pendingRelease = nil -- markBroken inside a tick: everything goes at the end of that tick
local recorded = ""        -- actor paths last written to the shared variable
local orphans = nil        -- hot reload: the previous Lua state's actor paths (destroyed on the game thread)
local lastTick = nil
local lastApplyMs = nil    -- last build (spawn / in-place rebuild) of any bay: SetupPreviewSpawnGapMs counts from it
local verbose = 0          -- per-pick lines at INFO for the first builds of the session, then dbg
local stats = { spawns = 0, rebuilds = 0, ready = 0, failed = 0, captures = 0, gapWaits = 0, bursts = 0, planes = 0,
                calibrations = 0 }
local fallen = {}          -- 0.12.0: [rung] = why: a backdrop rung that failed this session (the ladder skips it)
local cardCol = nil        -- 0.12.0: card colours per rung (backdrop(), brush()), made once
local capLog, capFirst, capSince = {}, 1, nil   -- capture times of the last CAPS_WINDOW_MS; start of this capture run
local capEvery = {}        -- 4-way garage: [key] = ms between two captures of a spinning bay (nil = SetupPreviewCaptureMs)
local outside = {}         -- 4-way garage: [owner] = the phase a host outside the front end allowed bays in (allowOutside)
local LIVERY_KEYS = { mask = "LiveryMaskTag", palette = "LiveryPaletteTag", patina = "PatinaTag", decal = "IconMaskTag",
                      decalColour = "IconPaletteTag" }
local LIVERY_ORDER = { "mask", "palette", "patina", "decal", "decalColour" }
local UI_SEL = { mask = 8, palette = 7, patina = 11, decal = 10, decalColour = 9 }   -- EVehicleRecipeUISelectionType

local function modeOf(b) return modes[b.i] or "spin" end

---------------------------------------------------------------------------------------------------- hot reload
local function sharedPut(v)
    pcall(function() ModRef:SetSharedVariable(C.MOD .. "." .. SHARED, v) end)
end

local function sharedGet()
    local ok, v = pcall(function() return ModRef:GetSharedVariable(C.MOD .. "." .. SHARED) end)
    if ok and type(v) == "string" then return v end
    return nil
end

-- Paths of every live bay actor -> the shared variable (game thread; only when they changed).
local function record()
    local parts = {}
    for _, b in pairs(bays) do
        for _, k in ipairs({ "veh", "cap", "fill", "back", "floor" }) do
            if b.path[k] then parts[#parts + 1] = b.path[k] end
        end
    end
    local s = table.concat(parts, "|")
    if s ~= recorded then
        recorded = s
        sharedPut(s)
    end
end

-- One of ours: a static vehicle / capture / light / backdrop plane of the current world, far above the sets (never
-- the game's).
local function isBayActor(a)
    if not (U.isA(a, VEH_NATIVE) or U.isA(a, CAPTURE) or U.isA(a, LIGHT) or U.isA(a, MESH_ACTOR)) then return false end
    local okW, w = pcall(U.callMethod, a, "GetWorld")
    if not (okW and U.same(w, U.world())) then return false end
    local ok, z = pcall(function() return tonumber(a:K2_GetActorLocation().Z) end)
    return ok and z ~= nil and z > num("SetupPreviewZ", 60000) - 30000
end

local function destroyOrphans()
    local list = orphans
    orphans = nil
    if type(list) ~= "string" or list == "" then return end
    local n, gone = 0, 0
    for path in list:gmatch("[^|]+") do
        local ok, a = pcall(StaticFindObject, path)
        if ok and U.ok(a) and isBayActor(a) then
            pcall(function() a:K2_DestroyActor() end)
            n = n + 1
        else
            gone = gone + 1
        end
    end
    U.log(TAG, "hot reload: %d preview actor(s) of the previous Lua state destroyed, %d already gone (V-VP-07)", n, gone)
end

local function adoptOrphans(v, how)
    if type(v) ~= "string" or v == "" or orphans ~= nil then return end
    orphans = v
    recorded = ""
    sharedPut("")
    U.log(TAG, "hot reload (%s): preview actors of the previous Lua state to destroy: %s", how, v)
    sched.run("vpreview.orphans", destroyOrphans)
end

-- main.lua PERSIST_MODULES contract (OnUnload, not the game thread: Lua values only).
function M.persistShared(put) put(SHARED, recorded) end
function M.restoreShared(get) adoptOrphans(get(SHARED), "restoreShared") end

---------------------------------------------------------------------------------------------------- spawning
-- Bay origin of key i. 0.10.0: spacing 20000 (was 5000): the fill light sits 0.85 x d toward the previous bay with
-- radius 3 x d, so at 15000 a pod's light still reached its neighbour's model (vehicle-step-v2.md §0.3 #7).
local function origin(i)
    return { X = num("SetupPreviewX", 0) + (i - 1) * num("SetupPreviewSpacing", 20000),
             Y = num("SetupPreviewY", 60000), Z = num("SetupPreviewZ", 60000) }
end

-- shown: the target holds a capture (the card shows it); fresh: that capture is of the applied pick, made after it
-- was ready (else the previous render, dimmed); burst: still captures left; due: a capture wanted this tick.
-- 0.12.0: rung = the backdrop the bay is built for (nil until its first build); post = the rung whose post-process the
-- capture carries (nil = untouched, today's); placed = the planes are where frame() put them; calibrated = the corner
-- read of V-FIN-05 is done (calibDue: this tick; calibAt: capN that arms it).
local function newBay(i)
    return { i = i, O = origin(i), gen = St.worldGen, wk = U.key(U.world()), path = {}, state = "idle",
             shown = false, everReady = false, fresh = false, burst = 0, due = false,
             rung = nil, post = nil, placed = false, calibrated = false, calibDue = false }
end

-- Deferred spawn (chasecam.spawnRig pattern). init(a) runs between BeginDeferredActorSpawnFromClass and
-- FinishSpawningActor (= before BeginPlay) in its own pcall, so a failed write never leaves a half-spawned actor.
-- Returns actor, nil, initError | nil, why.
local function spawn(cls, loc, init)
    local gs, world = U.GS(), U.world()
    if not (U.ok(cls) and U.ok(gs) and U.ok(world)) then return nil, "class/GameplayStatics/world missing" end
    local T = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
                Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local a, initErr
    local ok, err = pcall(function()
        a = gs:BeginDeferredActorSpawnFromClass(world, cls, T, SPAWN_ALWAYS, nil, SCALE_MULTIPLY)
        if not U.ok(a) then return end
        if init then
            local okI, e = pcall(init, a)
            if not okI then initErr = tostring(e) end
        end
        gs:FinishSpawningActor(a, T, SCALE_MULTIPLY)
    end)
    if not ok then
        if U.ok(a) then pcall(function() a:K2_DestroyActor() end) end
        return nil, "spawn error " .. tostring(err)
    end
    if not U.ok(a) then return nil, "spawn returned no actor" end
    return a, nil, initErr
end

-- Destroys bay actor k ("veh" | "cap" | "fill" | "back" | "floor") when it belongs to the current world. Returns 1 when
-- destroyed.
local function destroyActor(b, k)
    local a = b[k]
    b[k], b.path[k] = nil, nil
    if k == "cap" then b.comp = nil end
    if k == "back" then b.backMid = nil elseif k == "floor" then b.floorMid = nil end
    if a ~= nil and b.gen == St.worldGen and U.ok(a) then
        pcall(function() a:K2_DestroyActor() end)
        return 1
    end
    return 0
end

local function markBroken(why)
    if broken then return false end
    broken = tostring(why)
    pendingRelease = "broken"
    U.warn(TAG, "3D vehicle preview off for this session: %s; the vehicle cards keep the 2D art (V-VP-01)", broken)
    return false
end

local function failBay(b, id, why)
    b.state, b.applied, b.shown, b.fresh, b.burst, b.due = "failed", id, false, false, 0, false
    destroyActor(b, "veh")
    record()
    stats.failed = stats.failed + 1
    U.logOnce("vpreview.fail." .. tostring(id) .. "." .. tostring(why), TAG,
        "bay %d: %s not shown in 3D (%s): the column keeps the 2D card (V-VP-01)", b.i, tostring(id), tostring(why))
end

-- SetupPreviewExposure "fixed": eye adaptation clamped to SetupPreviewEV (EV100; the game uses the extended range)
-- on the capture's own post-process settings (struct fields written in place). "inherit": the front end's look.
local function exposure(c)
    if opt("SetupPreviewExposure", "inherit") ~= "fixed" then return end
    local ev = num("SetupPreviewEV", 8)
    local ok, err = pcall(function()
        local pp = c.PostProcessSettings
        pp.bOverride_AutoExposureMinBrightness = true
        pp.AutoExposureMinBrightness = ev
        pp.bOverride_AutoExposureMaxBrightness = true
        pp.AutoExposureMaxBrightness = ev
    end)
    U.logOnce("vpreview.exposure", TAG, "capture exposure fixed at EV100 %.2f: %s (V-VP-04)", ev, ok and "ok" or tostring(err))
end

-- Render target + capture (+ fill light) of bay b, made once. false = unavailable (markBroken logged why).
local function ensureInfra(b)
    if U.ok(b.cap) and U.ok(b.comp) and U.ok(b.rt) then return true end
    destroyActor(b, "cap")
    destroyActor(b, "fill")
    local krl = U.cdo(KRL)
    if not U.ok(krl) then return markBroken("KismetRenderingLibrary not found") end
    local ctx = U.gi()                                     -- the target's outer: never the world
    if not U.ok(ctx) then ctx = U.world() end
    local w, h, fmt = int("SetupPreviewW", 960), int("SetupPreviewH", 540), int("SetupPreviewRtFormat", 6)
    local okR, rt = pcall(function()
        return krl:CreateRenderTarget2D(ctx, w, h, fmt, { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }, false, false)
    end)
    if not (okR and U.ok(rt)) then
        return markBroken(string.format("CreateRenderTarget2D(%dx%d, format %d): %s", w, h, fmt, tostring(rt)))
    end
    local cap, why, initErr = spawn(U.class(CAPTURE), b.O, function(a)
        local c = a.CaptureComponent2D                     -- nothing renders before the target and the list exist
        c.bCaptureEveryFrame = false
        c.bCaptureOnMovement = false
        c.bAlwaysPersistRenderingState = true              -- eye adaptation / temporal history between captures
    end)
    if not cap then return markBroken("SceneCapture2D spawn: " .. tostring(why)) end
    b.cap, b.path.cap = cap, U.pathOf(cap)
    local okC, errC = pcall(function()
        local c = cap.CaptureComponent2D
        c.bCaptureEveryFrame = false
        c.bCaptureOnMovement = false
        c.CaptureSource = int("SetupPreviewCaptureSource", 2)                              -- 2 SCS_FinalColorLDR
        c.FOVAngle = num("SetupPreviewFov", 30)
        c.PrimitiveRenderMode = (opt("SetupPreviewShowOnly", true) == false) and 1 or 2   -- 2 PRM_UseShowOnlyList
        c.TextureTarget = rt
        b.comp = c
    end)
    if not (okC and U.ok(b.comp)) then
        destroyActor(b, "cap")
        return markBroken("capture component set-up: " .. tostring(okC and initErr or errC))
    end
    b.rt, b.rtW, b.rtH = rt, w, h
    b.post = nil                                           -- a new capture: today's post-process until backdropPost
    exposure(b.comp)
    if num("SetupPreviewFillLux", 60) > 0 then
        local fill, whyF = spawn(U.class(LIGHT), b.O, function(a) a.PointLightComponent:SetMobility(MOVABLE) end)
        if fill then
            b.fill, b.path.fill = fill, U.pathOf(fill)
            pcall(function()
                local L = fill.PointLightComponent
                L:SetIntensityUnits(CANDELAS)
                L:SetCastShadows(false)
            end)
        else
            U.logOnce("vpreview.fill", TAG, "fill light unavailable (%s): sun and sky light only (V-VP-04)", tostring(whyF))
        end
    end
    record()
    U.log(TAG, "bay %d at (%.0f, %.0f, %.0f): target %dx%d format %d, source %d, fov %.0f, %s, fill %s (V-VP-01)",
        b.i, b.O.X, b.O.Y, b.O.Z, w, h, fmt, int("SetupPreviewCaptureSource", 2), num("SetupPreviewFov", 30),
        opt("SetupPreviewShowOnly", true) == false and "all primitives" or "show-only list", b.fill and "on" or "off")
    return true
end

---------------------------------------------------------------------------------------------------- backdrop (0.12.0)
-- The rung asked for: "cutout" while UiStyle is "classic" (the 0.11.0 cards: today's capture), else PreviewBackdrop.
local function askedRung()
    if opt("UiStyle", "v2") == "classic" then return "cutout" end
    local r = opt("PreviewBackdrop", "studio")
    if r == "scenario" or r == "cutout" then return r end
    return "studio"
end

-- The rung in use: the asked one, else the first rung below it that has not failed this session.
local function rungNow()
    local r = askedRung()
    if r == "studio" and fallen.studio then r = "scenario" end
    if r == "scenario" and fallen.scenario then r = "cutout" end
    return r
end

-- A rung whose plane could not be built (or placed) is off for the session. quiet: the caller logs the whole fall (a
-- missing material drops both plane rungs) in one line. Returns true when the rung was still on.
local function fall(rung, why, quiet)
    if fallen[rung] then return false end
    fallen[rung] = tostring(why)
    if not quiet then
        U.warn(TAG, "backdrop %s off for this session (%s): %s from now on (V-FIN-05)", rung, fallen[rung], rungNow())
    end
    return true
end

-- PreviewStudioGain (V-FIN-05 calibration): a number or {r, g, b}, each > 0, multiplying STUDIO on the studio plane.
local function studioGain()
    local g = opt("PreviewStudioGain", 1)
    if type(g) == "number" and g > 0 and g < math.huge then return g, g, g end
    if type(g) == "table" then
        local r, gg, bl = tonumber(g[1] or g.R or g.r), tonumber(g[2] or g.G or g.g), tonumber(g[3] or g.B or g.b)
        if r and gg and bl and r > 0 and gg > 0 and bl > 0 and math.max(r, gg, bl) < math.huge then return r, gg, bl end
    end
    U.logOnce("vpreview.gain", TAG, "PreviewStudioGain %s ignored (a number or {r, g, b}, each > 0): 1", tostring(g))
    return 1, 1, 1
end

local function gainText()
    local r, g, bl = studioGain()
    if r == g and g == bl then return string.format("%.2f", r) end
    return string.format("{%.2f, %.2f, %.2f}", r, g, bl)
end

local function expText()
    if opt("SetupPreviewExposure", "inherit") ~= "fixed" then return "inherited" end
    return string.format("fixed at EV100 %.2f", num("SetupPreviewEV", 8))
end

-- Card colours per rung (§2.6 "building render", §10): fill = behind the class cut-out while a bay has no frame yet,
-- wash = over a "building" frame. theme's identity-stable tables (the diffed setters compare colours by identity);
-- vpreview's own copies of the same values when theme.lua cannot load (lazy: theme is not a group-1 module).
local function cardColours()
    if cardCol then return cardCol end
    local ok, T = pcall(U.mod, "theme")
    local K = ok and type(T) == "table" and type(T.alpha) == "function" and type(T.COL) == "table" and T.COL or nil
    if K and K.STUDIO and K.PAGE and K.BAND and K.PANEL then
        cardCol = { studio = { fill = K.STUDIO, wash = T.alpha(K.PAGE, 0.43) },
                    scenario = { fill = T.alpha(K.PANEL, 1), wash = T.alpha(K.BAND, 0.43) },   -- the texture's #1E353F
                    cutout = { fill = K.STUDIO } }
    else
        U.warn(TAG, "theme tokens unavailable (%s): the backdrop card colours are vpreview's copies",
            tostring(ok and "no COL" or T))
        local studio = { R = 0.7682, G = 0.7379, B = 0.6724, A = 1 }
        cardCol = { studio = { fill = studio, wash = { R = 0.8148, G = 0.8070, B = 0.7529, A = 0.43 } },
                    scenario = { fill = { R = 0.0130, G = 0.0369, B = 0.0482, A = 1 },
                                 wash = { R = 0.0273, G = 0.0595, B = 0.0666, A = 0.43 } },
                    cutout = { fill = studio } }
    end
    return cardCol
end

local function s2l(v)                                      -- sRGB channel (0..1) -> linear
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end

local function vec4(r, g, bl, a) return { R = r, G = g, B = bl, A = a or 1.0 } end   -- a new table per engine write

-- A transient MID of `path`. Its only UPROPERTY referencer will be a plane's material slot, set in this same tick (GC
-- rule, as brush()): the assets it needs are resolved before it is made. mid | nil, why.
local function newMid(path)
    local parent, kml = U.obj(path), U.cdo(KML)
    if not (U.ok(parent) and U.ok(kml)) then return nil, "material " .. path .. " not found" end
    local ok, mid = pcall(function()
        return kml:CreateDynamicMaterialInstance(U.world(), parent, U.fname("None"), MID_TRANSIENT)
    end)
    if not (ok and U.ok(mid)) then return nil, "CreateDynamicMaterialInstance(" .. path .. "): " .. tostring(mid) end
    return mid
end

-- The back plane's look for `rung` on b.backMid: studio = the white fill tinted STUDIO x PreviewStudioGain (tint alpha
-- 1: the Masked clip is 0.333); scenario = T_UI_Scenario_Bg, WHITE. tex: the resolved texture (nil = the material's
-- own white square). true | false, why.
local function paintBack(b, rung, tex)
    local mid = b.backMid
    if not U.ok(mid) then return false, "back plane material gone" end
    local col = vec4(1.0, 1.0, 1.0)
    if rung == "studio" then
        local gr, gg, gb = studioGain()
        col = vec4(STUDIO_LIN[1] * gr, STUDIO_LIN[2] * gg, STUDIO_LIN[3] * gb)
    end
    local ok, err = pcall(function()
        if U.ok(tex) then mid:SetTextureParameterValue(U.fname("SlateUI"), tex) end
        mid:SetVectorParameterValue(U.fname("TintColorAndOpacity"), col)
        mid:SetVectorParameterValue(U.fname("BackColor"), vec4(col.R, col.G, col.B))
    end)
    if not ok then return false, "back plane parameters: " .. tostring(err) end
    return true
end

-- One plane: a StaticMeshActor showing `mesh`, made movable before the mesh is set (a Static component refuses
-- SetStaticMesh once registered, and a deferred spawn registers native components before FinishSpawning), no
-- collision (the Plane is BlockAll; K2_TeleportTo then skips its encroachment check), no shadow, drawn by scene
-- captures only (never in a menu camera), material `mid`. actor | nil, why.
local function spawnPlane(b, mesh, mid, what)
    local a, why, initErr = spawn(U.class(MESH_ACTOR), b.O, function(x)
        local c = x.StaticMeshComponent
        c:SetMobility(MOVABLE)
        if c:SetStaticMesh(mesh) == false then error("SetStaticMesh refused") end
        c:SetCollisionEnabled(NO_COLLISION)
        c:SetCastShadow(false)
        c:SetVisibleInSceneCaptureOnly(true)
        c:SetMaterial(0, mid)
    end)
    if not a then return nil, what .. " spawn: " .. tostring(why) end
    if initErr then
        pcall(function() a:K2_DestroyActor() end)
        return nil, what .. " set-up: " .. initErr
    end
    stats.planes = stats.planes + 1
    return a
end

local function dropPlanes(b)
    local n = destroyActor(b, "back") + destroyActor(b, "floor")
    b.placed = false
    return n
end

-- The planes of `rung` (none for cutout). Assets first (T_UI_Scenario_Bg is a 4 MB NeverStream texture: one hitch per
-- session), then each MID and the plane that holds it. true | false, why (the caller drops what was built).
local function buildPlanes(b, rung)
    if rung == "cutout" then return true end
    local mesh = U.obj(PLANE_MESH)
    if not U.ok(mesh) then return false, "mesh " .. PLANE_MESH .. " not found" end
    local tex = U.obj(rung == "scenario" and SCEN_TEX or FILL_TEX)
    if not U.ok(tex) then
        if rung == "scenario" then return false, "texture " .. SCEN_TEX .. " not found" end
        tex = nil
        U.logOnce("vpreview.filltex", TAG, "%s not found: the studio plane keeps the material's white square", FILL_TEX)
    end
    local mid, why = newMid(UNLIT_MAT)
    if not mid then return false, why end
    local back
    back, why = spawnPlane(b, mesh, mid, "back plane")
    if not back then return false, why end
    b.back, b.path.back, b.backMid = back, U.pathOf(back), mid
    local okP, whyP = paintBack(b, rung, tex)
    if not okP then return false, whyP end
    if rung ~= "studio" or opt("PreviewStudioFloor", true) == false then return true end
    local fmid, whyF = newMid(FLOOR_MAT)
    if not fmid then return false, "floor: " .. tostring(whyF) end
    local okC, errC = pcall(function()
        fmid:SetVectorParameterValue(U.fname("Color"), vec4(FLOOR_LIN[1], FLOOR_LIN[2], FLOOR_LIN[3]))
    end)
    if not okC then return false, "floor Color: " .. tostring(errC) end
    local floor
    floor, whyF = spawnPlane(b, mesh, fmid, "floor plane")
    if not floor then return false, whyF end
    b.floor, b.path.floor, b.floorMid = floor, U.pathOf(floor), fmid
    return true
end

-- The capture's post-process for `rung`: studio forces the "fixed" exposure (SetupPreviewEV, §12.3), studio and
-- scenario turn the vignette off (a flat backdrop into the corners); back on cutout, what exposure() left (the
-- configured exposure, the front end's vignette). Nothing is written while a capture never left cutout (today's).
local function backdropPost(b, rung)
    local c = b.comp
    if not U.ok(c) or b.post == rung or (rung == "cutout" and b.post == nil) then return end
    local fixed = rung == "studio" or opt("SetupPreviewExposure", "inherit") == "fixed"
    local flat, ev = rung ~= "cutout", num("SetupPreviewEV", 8)
    local ok, err = pcall(function()
        local pp = c.PostProcessSettings                   -- struct fields written in place (as exposure())
        pp.bOverride_AutoExposureMinBrightness = fixed
        pp.bOverride_AutoExposureMaxBrightness = fixed
        if fixed then
            pp.AutoExposureMinBrightness = ev
            pp.AutoExposureMaxBrightness = ev
        end
        pp.bOverride_VignetteIntensity = flat
        if flat then pp.VignetteIntensity = 0.0 end
    end)
    b.post = rung
    U.logOnce("vpreview.post." .. rung .. "." .. tostring(fixed and ev), TAG,
        "backdrop %s: capture exposure %s, vignette %s: %s (V-FIN-05)", rung,
        fixed and string.format("fixed at EV100 %.2f", ev) or "inherited", flat and "off" or "restored",
        ok and "ok" or tostring(err))
end

-- A Lua error in the backdrop code: both plane rungs off for the session (cutout = today's capture), one WARN.
local function backdropBroken(b, err)
    local why = "error: " .. tostring(err):match("^[^\n]*")
    if not (fallen.studio and fallen.scenario) then
        fallen.studio, fallen.scenario = fallen.studio or why, fallen.scenario or why
        U.warn(TAG, "backdrop off for this session (%s): cutout from now on (V-FIN-05)", why)
    end
    pcall(dropPlanes, b)
    b.rung, b.calibDue = "cutout", false
    pcall(backdropPost, b, "cutout")
    record()
end

-- Bay b's backdrop for the rung in use (apply, after ensureInfra): built once, again when the rung, PreviewStudioFloor
-- or a plane changed. A rung whose plane cannot be built is dropped for the session and the next one is built at once.
-- Placement is frame()'s (the bounds are not known yet; until then no capture runs).
local function ensureBackdrop(b)
    local want = rungNow()
    local floor = want == "studio" and opt("PreviewStudioFloor", true) ~= false
    if not (b.rung == want and (want == "cutout" or U.ok(b.back)) and U.ok(b.floor) == floor) then
        local had, off = b.rung, {}
        dropPlanes(b)
        while want ~= "cutout" do
            local ok, why = buildPlanes(b, want)
            if ok then break end
            dropPlanes(b)
            if fall(want, why, true) then off[#off + 1] = want .. ": " .. tostring(why) end
            want = rungNow()
        end
        if #off > 0 then                                   -- the one log line of this fall
            U.warn(TAG, "backdrop off for this session (%s): %s from now on (V-FIN-05)", table.concat(off, "; "), want)
        end
        b.rung, b.calibrated, b.calibDue, b.calibAt = want, false, false, nil
        record()
        if want ~= had and opt("UiStyle", "v2") ~= "classic" then
            local what = "no plane: today's capture, the card shows the class cut-out on STUDIO ("
                .. (askedRung() == "cutout" and "PreviewBackdrop" or ("scenario off: " .. tostring(fallen.scenario))) .. ")"
            if want == "studio" then
                what = string.format("back plane STUDIO x %s%s, exposure fixed at EV100 %.2f", gainText(),
                    U.ok(b.floor) and " + lit floor #B9B4AB" or " (no floor)", num("SetupPreviewEV", 8))
            elseif want == "scenario" then
                what = "back plane T_UI_Scenario_Bg, exposure " .. expText()
                    .. (fallen.studio and (" (studio off: " .. fallen.studio .. ")") or "")
            end
            U.log(TAG, "bay %d backdrop %s: %s (V-FIN-05)", b.i, want, what)
        end
    end
    backdropPost(b, b.rung)
end

-- The planes for the camera frame() just placed (el, az: its elevation / azimuth seen from the bounds centre; hHalf,
-- vHalf: half FOVs). Back plane: square to the camera axis, BEHIND x the radius behind the centre, COVER x the frustum
-- at that depth, 16:9 like the target (local X = the camera's up, local Y = its right: the texture stands upright, its
-- +Z normal faces the camera); floor: FLOOR_GAP uu under the yaw-0 bounds (a turn about Z keeps the bottom), FLOOR_SIZE
-- x the radius, square to the camera's azimuth. Neither turns with the model. A plane that cannot be placed drops the
-- rung (a plane left at the bay origin would show inside the model).
local function placeBackdrop(b, el, az, hHalf, vHalf)
    if not (U.ok(b.back) or U.ok(b.floor)) then return end
    local Cn, E, r = b.box.C, b.box.E, b.box.r
    local okB, errB, okF, errF = true, nil, true, nil
    if U.ok(b.back) then
        local behind = BEHIND * r
        local depth = (b.dist or 0) + behind
        local w, h = 2 * depth * math.tan(hHalf) * COVER, 2 * depth * math.tan(vHalf) * COVER
        local ce = math.cos(el)
        local loc = { X = Cn.X - behind * ce * math.cos(az), Y = Cn.Y - behind * ce * math.sin(az),
                      Z = Cn.Z - behind * math.sin(el) }
        okB, errB = pcall(function()
            if b.back:K2_TeleportTo(loc, { Pitch = 90.0 - math.deg(el), Yaw = math.deg(az) + 180.0, Roll = 0.0 }) == false
            then error("K2_TeleportTo refused") end
            b.back:SetActorScale3D({ X = h / 100, Y = w / 100, Z = 1.0 })
        end)
    end
    if U.ok(b.floor) then
        local s = FLOOR_SIZE * r / 100
        okF, errF = pcall(function()
            if b.floor:K2_TeleportTo({ X = Cn.X, Y = Cn.Y, Z = Cn.Z - E.Z - FLOOR_GAP },
                { Pitch = 0.0, Yaw = math.deg(az), Roll = 0.0 }) == false then error("K2_TeleportTo refused") end
            b.floor:SetActorScale3D({ X = s, Y = s, Z = 1.0 })
        end)
    end
    if not (okB and okF) then
        fall(b.rung, "placement: " .. tostring(errB or errF))
        dropPlanes(b)
        b.rung, b.calibDue = "cutout", false
        backdropPost(b, "cutout")
        record()
        return
    end
    b.placed = true
    U.dbg(TAG, "bay %d backdrop %s placed: back plane %.0f uu behind, floor at z %.0f", b.i, tostring(b.rung),
        BEHIND * r, Cn.Z - E.Z - FLOOR_GAP)
end

-- One pixel of the target as sRGB bytes at (fx, fy) of its size: ReadRenderTargetPixel returns an FColor (a float
-- target comes back sRGB-encoded). A GPU readback flushes the render thread: once per bay (V-FIN-05). px | nil, why.
local function readPixel(b, fx, fy)
    local krl = U.cdo(KRL)
    if not (U.ok(krl) and U.ok(b.rt)) then return nil, "KismetRenderingLibrary / target missing" end
    local x = math.floor((b.rtW or int("SetupPreviewW", 960)) * fx)
    local y = math.floor((b.rtH or int("SetupPreviewH", 540)) * fy)
    local ok, r, g, bl = pcall(function()
        local c = krl:ReadRenderTargetPixel(U.world(), b.rt, x, y)
        return tonumber(c.R), tonumber(c.G), tonumber(c.B)
    end)
    if not (ok and r and g and bl) then return nil, tostring(ok and "no colour" or r) end
    local function byte(v) return math.max(0, math.min(255, math.floor(v + 0.5))) end
    return { byte(r), byte(g), byte(bl), x = x, y = y }
end

local function hexOf(p) return string.format("#%02X%02X%02X", p[1], p[2], p[3]) end

-- V-FIN-05: the target's top-left corner (the back plane) against #E3DFD6 +- 8 (studio; scenario logs its colour), with
-- the floor's colour (bottom-left corner) and a PreviewStudioGain suggestion (a linear ratio: the tonemapper bends it,
-- so a second calibrate() may be needed). One log line per bay.
local function calibrate(b)
    b.calibrated, b.calibDue = true, false
    stats.calibrations = stats.calibrations + 1
    local wall, err = readPixel(b, 0.03, 0.04)
    if not wall then
        U.warn(TAG, "bay %d backdrop %s: the render target corner could not be read (%s) (V-FIN-05)", b.i,
            tostring(b.rung), tostring(err))
        return
    end
    if b.rung ~= "studio" then
        U.log(TAG, "bay %d backdrop %s: RT corner (%d, %d) %s (the texture is #1E353F), exposure %s (V-FIN-05)", b.i,
            tostring(b.rung), wall.x, wall.y, hexOf(wall), expText())
        return
    end
    local floor = U.ok(b.floor) and readPixel(b, 0.03, 0.96) or nil
    local d = 0
    for k = 1, 3 do d = math.max(d, math.abs(wall[k] - STUDIO_SRGB[k])) end
    local verdict
    if math.max(wall[1], wall[2], wall[3]) < 8 then
        verdict = "FAIL: black, the back plane is not in the picture (culled, misplaced or not in the show-only list)"
    elseif d <= CALIB_TOL then
        verdict = string.format("PASS (max delta %d)", d)
    else
        local g, s = { studioGain() }, {}
        for k = 1, 3 do
            s[k] = math.max(0.05, math.min(64, g[k] * STUDIO_LIN[k] / math.max(1e-3, s2l(wall[k] / 255))))
        end
        verdict = string.format("FAIL (max delta %d): try PreviewStudioGain = {%.2f, %.2f, %.2f} and calibrate(); "
            .. "SetupPreviewEV moves the model and the floor; fallback PreviewBackdrop = \"scenario\"", d, s[1], s[2], s[3])
    end
    U.log(TAG, "bay %d backdrop studio: RT corner (%d, %d) %s, target #E3DFD6 +-%d, gain %s, exposure fixed at EV100 "
        .. "%.2f%s: %s (V-FIN-05)", b.i, wall.x, wall.y, hexOf(wall), CALIB_TOL, gainText(), num("SetupPreviewEV", 8),
        floor and (", floor " .. hexOf(floor)) or "", verdict)
end

---------------------------------------------------------------------------------------------------- models
local function vehicleClass()
    local c
    pcall(function() c = U.gi().StaticVehicleClass end)    -- ClassProperty +0x350 = BP_StaticVehicleBase_C
    if U.ok(c) then return c, "GfnGameInstance.StaticVehicleClass" end
    c = U.class(VEH_BP)
    if U.ok(c) then return c, "BP_StaticVehicleBase_C" end
    c = U.class(VEH_NATIVE)
    if U.ok(c) then return c, "CstStaticVehicle" end
    return nil, "no static vehicle class (StaticVehicleClass, BP_StaticVehicleBase_C, CstStaticVehicle)"
end

-- true when veh.preset reads back cls (a ClassProperty write needs a UClass and silently ignores nil), else false, name.
local function presetIs(veh, cls)
    local ok, got = pcall(U.getField, veh, "preset")
    if not ok then return false, "unreadable" end
    if U.same(got, cls) then return true end
    local n = "None"
    if U.ok(got) then pcall(function() n = got:GetFName():ToString() end) end   -- an unset preset reads a NULL wrapper
    return false, n
end

local function say(f, ...)
    if verbose <= 8 then U.log(TAG, f, ...) else U.dbg(TAG, f, ...) end
end

-- The newest pick w of bay b goes into the model (M.tick debounces and spaces the builds: nextApply).
local function apply(b, w, now)
    local gap = lastApplyMs and math.floor(now - lastApplyMs) or nil
    lastApplyMs = now                                      -- every attempt counts: ensureInfra spawns too
    if not ensureInfra(b) then return end
    local okB, errB = xpcall(ensureBackdrop, debug.traceback, b)   -- 0.12.0: planes of the rung in use (cutout: none)
    if not okB then backdropBroken(b, errB) end
    local cls = V.presetClass(w.p)
    if not cls then return failBay(b, w.id, "preset class not resolvable: " .. tostring(w.p.classPath)) end
    local update = opt("SetupPreviewRebuild", "respawn") == "update" and U.ok(b.veh)
    local how
    if update then
        local ok, err = pcall(function()
            b.veh.preset = cls
            b.veh.PlayerVehicleToUse = w.arch
            b.veh:UpdateCustomisationMesh()
        end)
        if not ok then return failBay(b, w.id, "UpdateCustomisationMesh: " .. tostring(err)) end
        how = "rebuilt in place"
        stats.rebuilds = stats.rebuilds + 1
    else
        destroyActor(b, "veh")
        local vc, vcName = vehicleClass()
        if not vc then return markBroken(vcName) end
        local veh, why, initErr = spawn(vc, b.O, function(a)
            a.preset = cls                                 -- before FinishSpawning: the spawn builds this model
            a.PlayerVehicleToUse = w.arch
        end)
        if not veh then return markBroken("vehicle spawn (" .. vcName .. "): " .. tostring(why)) end
        b.veh, b.path.veh = veh, U.pathOf(veh)
        record()
        if initErr then return markBroken("preset write refused: " .. initErr) end
        how = "spawned (" .. vcName .. ")"
        stats.spawns = stats.spawns + 1
    end
    local okP, got = presetIs(b.veh, cls)
    if not okP then return markBroken("preset write ignored (preset reads " .. tostring(got) .. ")") end
    pcall(function() b.veh:K2_TeleportTo(b.O, ZERO_ROT) end)
    b.applied, b.state, b.since, b.sample, b.nextSample = w.id, "building", now, nil, 0
    b.fresh, b.burst, b.lateBurst, b.modeChanged = false, 0, false, false
    b.lsig = ""                                            -- 4-way garage: a (re)built model wears its preset's livery
    verbose = verbose + 1
    say("bay %d: %s %s (%s, archetype %d, %s, %s) (V-VP-%s, V-RC-17)", b.i, w.id, how, tostring(w.p.name), w.arch,
        modeOf(b), gap and string.format("%d ms after the previous build", gap) or "first build", update and "02" or "01")
end

---------------------------------------------------------------------------------------------------- readiness
local function vec(fn)
    local ok, x, y, z = pcall(function()
        local v = fn()
        return tonumber(v.X), tonumber(v.Y), tonumber(v.Z)
    end)
    if ok and x and y and z then return { X = x, Y = y, Z = z } end
    return nil
end

local function unitCount(veh)
    local ok, n = pcall(function() return veh.CustomisationComponent:GetUnitContainerCount() end)
    if ok then return tonumber(n) end
    return nil
end

-- Actor bounds (two struct out-params: UE4SS fills each table in place). nil when unreadable / NaN.
local function bounds(veh, colliding)
    local O, E = {}, {}
    if not pcall(function() veh:GetActorBounds(colliding, O, E, true) end) then return nil end
    local v = { tonumber(O.X), tonumber(O.Y), tonumber(O.Z), tonumber(E.X), tonumber(E.Y), tonumber(E.Z) }
    for k = 1, 6 do if v[k] == nil or v[k] ~= v[k] then return nil end end
    return { C = { X = v[1], Y = v[2], Z = v[3] }, E = { X = v[4], Y = v[5], Z = v[6] },
             r = math.sqrt(v[4] * v[4] + v[5] * v[5] + v[6] * v[6]) }
end

-- Model bounds at yaw 0: all components (what the show-only capture draws) or the colliding ones
-- (SetupPreviewBounds); the other kind when the first is degenerate (< 20 uu) or beyond SetupPreviewMaxRadius.
local function measure(b)
    local coll = opt("SetupPreviewBounds", "all") == "colliding"
    local maxR = num("SetupPreviewMaxRadius", 6000)
    local first = bounds(b.veh, coll)
    if first and first.r >= 20 and first.r <= maxR then first.kind = coll and "colliding" or "all"; return first end
    local second = bounds(b.veh, not coll)
    if second and second.r >= 20 and second.r <= maxR then second.kind = coll and "all" or "colliding"; return second end
    return nil, string.format("bounds r %s / %s", first and string.format("%.0f", first.r) or "?",
        second and string.format("%.0f", second.r) or "?")
end

-- Camera on the sun side (azimuth SetupPreviewCamYaw, SetupPreviewCamPitch above the horizon) aimed at the bounds
-- centre, far enough for every turntable yaw: the yaw-0 box turns inside a cylinder of radius rh, its projected half
-- height is E.Z cos(el) + rh sin(el). The fill light sits above the camera: candela = lux * metres^2.
local function frame(b)
    local E, Cn = b.box.E, b.box.C
    local hHalf = math.rad(num("SetupPreviewFov", 30)) / 2
    local vHalf = math.atan(math.tan(hHalf) / (num("SetupPreviewW", 960) / num("SetupPreviewH", 540)))
    local el, az = math.rad(num("SetupPreviewCamPitch", 12)), math.rad(num("SetupPreviewCamYaw", 210))
    local rh = math.sqrt(E.X * E.X + E.Y * E.Y)
    local rv = E.Z * math.cos(el) + rh * math.sin(el)
    local d = math.max(rh / math.sin(hHalf), rv / math.sin(vHalf)) * num("SetupPreviewFrame", 1.05)
    local cam = { X = Cn.X + d * math.cos(el) * math.cos(az), Y = Cn.Y + d * math.cos(el) * math.sin(az),
                  Z = Cn.Z + d * math.sin(el) }
    pcall(function() b.cap:K2_TeleportTo(cam, { Pitch = -math.deg(el), Yaw = math.deg(az) + 180.0, Roll = 0.0 }) end)
    b.dist = d
    if U.ok(b.fill) then
        local up = d * 0.35
        local m = math.sqrt(d * d + up * up) / 100
        pcall(function()
            b.fill:K2_TeleportTo({ X = cam.X, Y = cam.Y, Z = cam.Z + up }, ZERO_ROT)
            local L = b.fill.PointLightComponent
            L:SetIntensity(num("SetupPreviewFillLux", 60) * m * m)
            L:SetAttenuationRadius(d * 3)
        end)
    end
    local okP, errP = pcall(placeBackdrop, b, el, az, hHalf, vHalf)   -- 0.12.0: the planes follow the camera
    if not okP then backdropBroken(b, errP) end
end

local function showOnly(b)
    if opt("SetupPreviewShowOnly", true) == false then return end
    pcall(function()
        b.comp:ClearShowOnlyComponents()
        b.comp:ShowOnlyActorComponents(b.veh, true)        -- UFunctions: never write the TArray from Lua
    end)
    for _, k in ipairs({ "back", "floor" }) do              -- 0.12.0 backdrop planes (§10): in the picture, never turned
        if U.ok(b[k]) then pcall(function() b.comp:ShowOnlyActorComponents(b[k], true) end) end
    end
end

-- SetupPreviewCaptureOnly (V-VP-05 fallback): the model is drawn by scene captures only and casts no shadow.
local function captureOnly(b)
    if opt("SetupPreviewCaptureOnly", false) ~= true then return end
    local n = 0
    pcall(function()
        for _, comp in ipairs(U.arrayToTable(b.veh:K2_GetComponentsByClass(U.class(PRIMITIVE)))) do
            if U.ok(comp) and pcall(function() comp:SetVisibleInSceneCaptureOnly(true); comp:SetCastShadow(false) end) then
                n = n + 1
            end
        end
    end)
    U.dbg(TAG, "bay %d: %d component(s) visible in scene captures only", b.i, n)
end

-- The model turned to `yaw` about its bounds centre (pivot = its location at yaw 0).
local function spinTo(b, yaw)
    local a, Cn, P = math.rad(yaw), b.box.C, b.pivot
    local dx, dy = P.X - Cn.X, P.Y - Cn.Y
    local loc = { X = Cn.X + dx * math.cos(a) - dy * math.sin(a), Y = Cn.Y + dx * math.sin(a) + dy * math.cos(a),
                  Z = P.Z }
    pcall(function() b.veh:K2_TeleportTo(loc, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }) end)
end

-- Capture times for stats().capturesPerSec (the window holds ~300 entries at 30 captures/s).
local function noteCapture(now)
    while capFirst <= #capLog and now - capLog[capFirst] > CAPS_WINDOW_MS do capFirst = capFirst + 1 end
    if capFirst > #capLog then capSince = now end          -- a new run of captures: its rate counts from here
    capLog[#capLog + 1] = now
    if capFirst > 512 then
        local keep = {}
        for k = capFirst, #capLog do keep[#keep + 1] = capLog[k] end
        capLog, capFirst = keep, 1
    end
end

-- Only M.tick captures (the budget). A capture of a ready model puts the applied pick on the card (shown, fresh).
local function capture(b, now)
    local ok, err = pcall(function() b.comp:CaptureScene() end)
    b.lastCap, b.capN = now, (b.capN or 0) + 1
    if (b.burst or 0) > 0 then b.burst = b.burst - 1 end
    if not ok then
        U.logOnce("vpreview.capture." .. tostring(b.i), TAG, "bay %d: CaptureScene failed: %s", b.i, tostring(err))
        return
    end
    stats.captures = stats.captures + 1
    noteCapture(now)
    if b.state == "ready" then
        b.shown, b.fresh = true, true
        -- 0.12.0 V-FIN-05: the backdrop's corner is read once per bay, after CALIB_CAPS captures of a ready model
        if cfg.PreviewCalibrate == true and b.placed and not b.calibrated and b.rung ~= nil and b.rung ~= "cutout"
            and b.capN >= (b.calibAt or CALIB_CAPS) then b.calibDue = true end
    end
end

-- RC-12: a still is a burst of SetupPreviewStillBurst captures on consecutive budget slots (Lumen GI / reflections,
-- TSR and eye adaptation accumulate over captures; one or three captures do not converge).
local function arm(b, why)
    b.burst = math.max(1, int("SetupPreviewStillBurst", 8))
    stats.bursts = stats.bursts + 1
    U.dbg(TAG, "bay %d: still burst of %d capture(s) (%s)", b.i, b.burst, tostring(why))
end

-- 4-way garage: the bay's wanted livery differs from the one on its ready model (want.lsig: "" = no livery control)
local function liveryPending(b)
    local w = b.want
    if not (w and w.id == b.applied and w.lsig and w.lsig ~= "") then return false end
    return w.lsig ~= b.lsig
end

-- The wanted tags onto the model (cfg.Garage4BayLivery), then the bay waits for the model again (same readiness test:
-- the next capture shows the livery). A refusal is logged once per bay and pick and never retried for that livery.
local function applyLivery(b, now)
    local w = b.want
    b.lsig = w.lsig
    local mode = opt("Garage4BayLivery", "refresh")
    if mode == "off" then return false end
    local comp = nil
    pcall(function() comp = b.veh.CustomisationComponent end)
    if not U.ok(comp) then
        U.logOnce("vpreview.livery.comp." .. b.i, TAG, "bay %d: no CustomisationComponent: livery not shown", b.i)
        return false
    end
    local ok, err
    if mode == "ui" then
        ok, err = pcall(function()
            for _, k in ipairs(LIVERY_ORDER) do
                local tag = w.livery[k]
                if tag then comp:UpdateUISelection(UI_SEL[k], tag, -1) end
            end
        end)
    else
        ok, err = pcall(function()
            local rec = comp.ActiveRecipe
            if not U.ok(rec) then error("no ActiveRecipe") end
            local n = U.objName(rec) or ""
            if n:find("^Default__") then error("ActiveRecipe is a class default object") end
            for _, k in ipairs(LIVERY_ORDER) do
                local tag = w.livery[k]
                if tag then rec[LIVERY_KEYS[k]] = { TagName = U.fname(tag) } end
            end
            comp:RefreshRecipe()
        end)
    end
    if not ok then
        U.logOnce("vpreview.livery." .. b.i .. "." .. tostring(w.lsig), TAG, "bay %d: livery not shown (%s): %s", b.i,
            mode, tostring(err))
        return false
    end
    b.state, b.since, b.sample, b.nextSample = "building", now, nil, 0
    b.fresh, b.burst, b.lateBurst = false, 0, false
    stats.liveries = (stats.liveries or 0) + 1
    say("bay %d: livery %s on %s (%s) (G4-02)", b.i, w.lsig, tostring(b.applied), mode)
    return true
end

local function becomeReady(b, box, now, how)
    b.box = box
    b.pivot = vec(function() return b.veh:K2_GetActorLocation() end) or { X = b.O.X, Y = b.O.Y, Z = b.O.Z }
    frame(b)
    showOnly(b)
    captureOnly(b)
    pcall(function() b.veh:PrestreamTextures(10.0, true, 0) end)
    b.yaw = num("SetupPreviewYaw", 245) % 360
    spinTo(b, b.yaw)
    b.state, b.readyAt, b.prestreamAt, b.nextLate, b.capN = "ready", now, now, now + 500, 0
    b.everReady, b.fresh, b.lateBurst, b.modeChanged = true, false, false, false
    b.calibAt = nil                                        -- 0.12.0: capN restarted (V-FIN-05 read after CALIB_CAPS)
    if modeOf(b) == "still" then arm(b, "ready") else b.burst = 0 end
    b.due = true                                           -- the first capture: this tick's budget (M.tick)
    stats.ready = stats.ready + 1
    local E = box.E
    say("bay %d ready: %s, %s unit(s), %s bounds %.0fx%.0fx%.0f (r %.0f), camera %.0f uu, %d ms, %s, %s (V-VP-01)",
        b.i, tostring(b.applied), tostring(box.count), tostring(box.kind), 2 * E.X, 2 * E.Y, 2 * E.Z, box.r,
        b.dist or 0, math.floor(now - b.since), how, modeOf(b))
    -- 4-way garage: the livery first (no capture of the preset's own look; the bay waits for the model again)
    if liveryPending(b) and applyLivery(b, now) then b.due = false end
end

local function checkBuild(b, now)
    if not U.ok(b.veh) then return failBay(b, b.applied, "the model actor vanished") end
    local age = now - b.since
    if age < SETTLE_MS or now < (b.nextSample or 0) then return end
    b.nextSample = now + SAMPLE_MS
    local count = unitCount(b.veh)
    local box, why
    if count and count > 0 then box, why = measure(b) end
    if box then
        local prev = b.sample
        box.count = count
        b.sample = box
        if prev and prev.count == count and math.abs(prev.r - box.r) <= 0.03 * box.r then
            return becomeReady(b, box, now, "stable")
        end
    end
    if age > int("SetupPreviewTimeoutMs", 6000) then
        if b.sample then return becomeReady(b, b.sample, now, "timeout, bounds still changing") end
        return failBay(b, b.applied, string.format("not built after %d ms (unit containers %s, %s)", math.floor(age),
            tostring(count), why or "no bounds"))
    end
end

-- Yaw-0 bounds again (teleport, measure, back: inside one game-thread tick, no frame sees it); framed again when
-- the model grew or shrank by more than 4 % (parts built after "ready").
local function remeasure(b)
    pcall(function() b.veh:K2_TeleportTo(b.pivot, ZERO_ROT) end)
    local box = measure(b)
    if box and math.abs(box.r - b.box.r) > 0.04 * b.box.r then
        U.dbg(TAG, "bay %d: late parts, r %.0f -> %.0f: framed again", b.i, b.box.r, box.r)
        box.count = b.box.count
        b.box = box
        frame(b)
    end
    spinTo(b, b.yaw)
end

-- A model that falls (physics on the static vehicle's root, vehicle-preview.md §6.8) is put back, physics off.
-- true = it was put back.
local function dropCheck(b, now)
    if now < (b.nextDrop or 0) then return false end
    b.nextDrop = now + 500
    local p = vec(function() return b.veh:K2_GetActorLocation() end)
    if not p or p.Z >= b.pivot.Z - 50 then return false end
    U.logOnce("vpreview.drop", TAG, "bay %d: the model falls (z %.0f < %.0f): physics off, put back (V-VP-01)", b.i,
        p.Z, b.pivot.Z)
    pcall(function() b.veh.CstRootComponent:SetSimulatePhysics(false) end)
    spinTo(b, b.yaw)
    return true
end

-- A ready bay: late-part refresh, prestream, drop check, then the mode decides whether a capture is due (b.due; the
-- capture itself is M.tick's, within SetupPreviewCaptureBudget).
local function runReady(b, now, dt)
    if not (U.ok(b.veh) and U.ok(b.comp)) then return failBay(b, b.applied, "a bay actor vanished") end
    if liveryPending(b) and applyLivery(b, now) then return end          -- 4-way garage: a new livery, no respawn
    local age = now - b.readyAt
    if age <= LATE_MS and now >= (b.nextLate or 0) then
        b.nextLate = now + 500
        showOnly(b)
        remeasure(b)
    end
    if now - (b.prestreamAt or 0) >= 8000 then
        b.prestreamAt = now
        pcall(function() b.veh:PrestreamTextures(10.0, true, 0) end)
    end
    local still = modeOf(b) == "still"
    if dropCheck(b, now) and still then arm(b, "put back") end
    if b.modeChanged then                                  -- setMode: to the still yaw, or the turntable goes on
        b.modeChanged = false
        if still then
            b.yaw = num("SetupPreviewYaw", 245) % 360
            spinTo(b, b.yaw)
            b.lateBurst = b.lateBurst or age > LATE_MS     -- this burst already has the late parts
            arm(b, "mode still")
        else
            b.burst = 0
        end
    end
    if still then
        if age > LATE_MS and not b.lateBurst then          -- again once the parts built after "ready" are in the picture
            b.lateBurst = true
            arm(b, "late parts")
        end
        b.due = (b.burst or 0) > 0
        return
    end
    local dps = num("SetupPreviewSpinDps", 15)
    if dps ~= 0 then
        b.yaw = (b.yaw + dps * dt / 1000) % 360
        spinTo(b, b.yaw)
        local every = capEvery[b.i] or num("SetupPreviewCaptureMs", 66)
        b.due = every <= 0 or now - (b.lastCap or 0) >= every - CAPTURE_SLACK_MS
    else
        local at = STATIC_CAPS[(b.capN or 0) + 1]
        if at then b.due = age >= at else b.due = now - (b.lastCap or 0) >= 5000 end
    end
end

local function tickBay(b, now, dt)
    b.due = false
    if broken then return end
    if b.state == "building" then checkBuild(b, now)
    elseif b.state == "ready" then runReady(b, now, dt) end
end

-- The bay whose pick is built next: debounced (SetupPreviewDebounceMs), the oldest waiting pick first; nil while
-- SetupPreviewSpawnGapMs has not passed since the previous build of any bay (one spawn hitch at a time, V-RC-17).
local function nextApply(now)
    local debounce, pick = int("SetupPreviewDebounceMs", 250), nil
    for _, b in pairs(bays) do
        local w = b.want
        if w and w.id ~= b.applied and now - w.at >= debounce and (pick == nil or w.at < pick.want.at) then pick = b end
    end
    if pick and lastApplyMs and now - lastApplyMs < int("SetupPreviewSpawnGapMs", 300) then
        if not pick.want.gapWait then
            pick.want.gapWait = true
            stats.gapWaits = stats.gapWaits + 1
        end
        return nil
    end
    return pick
end

-- What a card shows of bay b (render or 2D card, dimmed or not): a change re-renders the card.
local function sig(b)
    return b.state .. "|" .. tostring(b.shown) .. "|" .. tostring(b.fresh) .. "|" .. tostring(b.applied) .. "|"
        .. tostring(b.lsig)
end

local function allKeys()
    local keys = {}
    for i in pairs(bays) do keys[i] = true end
    return keys
end

---------------------------------------------------------------------------------------------------- API (setup.lua)
-- false, why when no 3D preview can be shown (setting off, broken, outside the front end).
function M.enabled()
    if opt("SetupPreview3D", true) == false then return false, "SetupPreview3D = false" end
    if broken then return false, broken end
    if St.phase ~= "FRONTEND" then
        for _, ph in pairs(outside) do
            if ph == St.phase then return true end         -- 4-way garage in the paddock (allowOutside)
        end
        return false, "phase " .. tostring(St.phase)
    end
    return true
end

-- 4-way garage (couch campaign): owner's bays may live outside the front end, in the CURRENT phase only (a phase change
-- drops the grant and releases every bay). on = false: the grant goes (the caller releases its bays).
function M.allowOutside(owner, on)
    outside[tostring(owner)] = on and St.phase or nil
end

-- 4-way garage: ms between two captures of key i's bay while it spins (nil = SetupPreviewCaptureMs). Pure Lua.
function M.setCaptureMs(i, ms)
    capEvery[i] = (tonumber(ms) and ms > 0) and ms or nil
end

function M.aspect() return num("SetupPreviewW", 960) / num("SetupPreviewH", 540) end

-- Key i (classic: the column; RACERS: ControllerId + 1) shows preset entry p (vehicles.presets) of class entry cls.
-- Idempotent: the build starts in tick() once the pick has not changed for SetupPreviewDebounceMs (and at most one
-- build per SetupPreviewSpawnGapMs over all bays).
function M.want(i, p, cls, livery)
    if not M.enabled() or type(p) ~= "table" or type(p.id) ~= "string" or type(cls) ~= "table" then return end
    local b = bays[i]
    if b and b.gen ~= St.worldGen then bays[i], b = nil, nil end
    if not b then
        b = newBay(i)
        bays[i] = b
    end
    -- 4-way garage: the livery's signature ("" = none asked: the bay keeps whatever its model wears)
    local lsig = ""
    if type(livery) == "table" then
        local parts = {}
        for _, k in ipairs(LIVERY_ORDER) do parts[#parts + 1] = tostring(livery[k] or "-") end
        lsig = table.concat(parts, "|")
    end
    if b.want and b.want.id == p.id then
        if lsig ~= "" and b.want.lsig ~= lsig then b.want.livery, b.want.lsig = livery, lsig end
        return
    end
    b.want = { id = p.id, p = p, arch = math.floor(tonumber(cls.arch) or 0), at = St.nowMs(),
               livery = (lsig ~= "") and livery or nil, lsig = lsig }
end

-- 4-way garage: key i's bay shows its applied pick WITH the wanted livery (the area's image is current).
function M.liveryShown(i)
    local b = bays[i]
    if not (b and b.want) then return false end
    return b.state == "ready" and b.fresh and b.want.id == b.applied and (b.want.lsig == "" or b.want.lsig == b.lsig)
end

-- Mode of key i's bay: "spin" (turntable, a capture every SetupPreviewCaptureMs) | "still" (SetupPreviewYaw, bursts
-- of SetupPreviewStillBurst captures, then none until the pick changes). Cheap when unchanged (racers.lua sets it every
-- FAST tick); kept for a key without a bay yet; dropped with the bay (release / releaseAll). Pure Lua: the turn and
-- the burst happen in the next tick().
function M.setMode(i, mode)
    if mode ~= "spin" and mode ~= "still" then return end
    local was = modes[i] or "spin"
    if modes[i] == mode then return end
    modes[i] = mode
    local b = bays[i]
    if b and was ~= mode then b.modeChanged = true end
end

-- The mode of a RACERS card's bay on `stage` ("pilot" | "vehicle" | "perks" | "ready"), by SetupPreviewSpinStage:
-- "vehicle" spins on VEHICLE only, "all" on every stage, "none" never (stills only).
function M.stageMode(stage)
    local s = opt("SetupPreviewSpinStage", "vehicle")
    if s == "all" then return "spin" end
    if s == "none" then return "still" end
    return stage == "vehicle" and "spin" or "still"
end

-- Every ready "still" bay captures a new burst (RC-12: the page was shown again). Pure Lua; returns the bay count.
function M.recapture(why)
    local n = 0
    for _, b in pairs(bays) do
        if b.state == "ready" and modeOf(b) == "still" then
            arm(b, why or "recapture")
            n = n + 1
        end
    end
    return n
end

-- What key i shows: brush, kind, alpha multiplier, aspect, base, wash; nil = the 2D card. The previous model stays
-- while a new pick builds, until the first capture of the new one. The MID is made here, in the tick that puts it on
-- the image: an object only Lua knows (no UPROPERTY reference) may be garbage collected.
--   kind  "material" | "texture": a capture of the applied pick; 0.12.0 "building" (§12.2): a studio / scenario bay
--         shows an older frame: the card draws `wash` over it (dim is then 1: the wash replaces the 0.5 dim, which
--         turns a cream photo grey). A cutout bay (UiStyle "classic" included) keeps today's kind and DIM.
--   base  "material" | "texture": what the brush is, also while "building" (pick the image setter by it);
--   wash  {R, G, B, A}: PAGE @0.43 (studio) | BAND @0.43 (scenario) while "building", else nil (theme's tables).
function M.brush(i)
    if not M.enabled() then return nil end
    local b = bays[i]
    if not (b and b.shown and U.ok(b.rt)) then return nil end
    local fresh = b.state == "ready" and b.fresh and b.want ~= nil and b.want.id == b.applied
        and (b.want.lsig == nil or b.want.lsig == "" or b.want.lsig == b.lsig)
    local base = opt("SetupPreviewBrush", "material") == "texture" and "texture" or "material"
    local wash = (not fresh and b.rung ~= nil and b.rung ~= "cutout") and cardColours()[b.rung].wash or nil
    local kind, dim = base, fresh and 1.0 or DIM
    if wash then kind, dim = "building", 1.0 end
    if base == "texture" then return b.rt, kind, dim, M.aspect(), base, wash end
    if not U.ok(b.mid) then
        b.mid = nil
        local path, param = opt("SetupPreviewMaterial", RBMAT), opt("SetupPreviewMaterialParam", "Texture")
        local parent, kml = U.obj(path), U.cdo(KML)
        if not (U.ok(parent) and U.ok(kml)) then return nil, markBroken("material " .. tostring(path) .. " not found") end
        local ok, mid = pcall(function()
            return kml:CreateDynamicMaterialInstance(U.world(), parent, U.fname("None"), MID_TRANSIENT)
        end)
        if not (ok and U.ok(mid)) then return nil, markBroken("CreateDynamicMaterialInstance: " .. tostring(mid)) end
        local okP, errP = pcall(function() mid:SetTextureParameterValue(U.fname(param), b.rt) end)
        if not okP then
            return nil, markBroken("SetTextureParameterValue(" .. tostring(param) .. "): " .. tostring(errP))
        end
        b.mid = mid
        U.logOnce("vpreview.mid", TAG, "column image = MID of %s, texture parameter %s (V-VP-03)", path, tostring(param))
    end
    return b.mid, kind, dim, M.aspect(), base, wash
end

-- 0.12.0 (§10): the backdrop of key i, for the card around the render. rung "studio" | "scenario" | "cutout" (the
-- bay's, else the rung a bay would get now; "cutout" while no 3D preview can be shown), fill = the colour behind the
-- class cut-out while there is no frame yet (STUDIO; scenario PANEL, T_UI_Scenario_Bg's own teal), wash = the colour
-- over a "building" frame (PAGE / BAND @0.43; nil for cutout: today's dim). On "cutout" the v2 card shows the class
-- cut-out on the fill instead of the render (§10: no live render). Pure Lua; theme's identity-stable colour tables.
function M.backdrop(i)
    local r = "cutout"
    if M.enabled() then
        local b = bays[i]
        r = (b and b.rung) or rungNow()
    end
    local c = cardColours()[r]
    return r, c.fill, c.wash
end

-- 0.12.0 test.cmd (V-FIN-05 calibration): the backdrop of key i (nil = every bay) takes the current PreviewStudioGain
-- and SetupPreviewEV, and its corner is read again after CALIB_CAPS more captures (a still bay captures a new burst).
-- Returns a text.
function M.calibrate(i)
    local n = 0
    for k, b in pairs(bays) do
        if (i == nil or k == i) and b.rung ~= nil and b.rung ~= "cutout" then
            b.post = nil
            backdropPost(b, b.rung)
            if b.rung == "studio" and U.ok(b.backMid) then
                local ok, why = paintBack(b, "studio", nil)
                if not ok then U.warn(TAG, "bay %d calibrate: %s", b.i, tostring(why)) end
            end
            b.calibrated, b.calibDue, b.calibAt = false, false, (b.capN or 0) + CALIB_CAPS
            if b.state == "ready" and modeOf(b) == "still" then arm(b, "calibrate") end
            n = n + 1
        end
    end
    return string.format("%d bay(s) re-armed for the corner read: backdrop %s, gain %s, EV100 %.2f (V-FIN-05)", n,
        rungNow(), gainText(), num("SetupPreviewEV", 8))
end

-- FAST (setup.pollNav while the VEHICLES / RACERS step shows). Returns changed, keys: changed = what a card shows
-- changed (setup / racers re-render), keys = {[key] = true} for each bay that changed or went (classic setup reads
-- only the first value). Order: drop bays of another world, one build (spawn gap), every bay's build / ready tick,
-- then the capture budget over the due bays.
function M.tick()
    if pendingRelease then
        local keys = allKeys()
        M.releaseAll(pendingRelease)
        return true, keys
    end
    if next(bays) == nil then lastTick = nil; return false, {} end
    local on, why = M.enabled()
    if not on then
        local keys = allKeys()
        M.releaseAll(why)
        return true, keys
    end
    local now = St.nowMs()
    local dt = lastTick and math.max(0, math.min(200, now - lastTick)) or 33
    lastTick = now
    local wk, keys, before = U.key(U.world()), {}, {}
    for i, b in pairs(bays) do
        if b.gen ~= St.worldGen or (b.wk ~= 0 and wk ~= 0 and b.wk ~= wk) then
            bays[i], keys[i] = nil, true                   -- another world: the old one took the actors with it
        else
            before[i] = sig(b)
        end
    end
    local nb = nextApply(now)
    if nb then
        local ok, err = xpcall(apply, debug.traceback, nb, nb.want, now)
        if not ok then
            U.dbg(TAG, "bay %d build error: %s", nb.i, tostring(err))
            failBay(nb, nb.want.id, "error: " .. tostring(err):match("^[^\n]*"))
        end
    end
    for _, b in pairs(bays) do
        local ok, err = xpcall(tickBay, debug.traceback, b, now, dt)
        if not ok then
            U.dbg(TAG, "bay %d tick error: %s", b.i, tostring(err))
            failBay(b, b.want and b.want.id or b.applied, "error: " .. tostring(err):match("^[^\n]*"))
        end
    end
    if pendingRelease then
        for i in pairs(bays) do keys[i] = true end
        M.releaseAll(pendingRelease)
        return true, keys
    end
    -- capture budget: SetupPreviewCaptureBudget captures per tick, the due bay captured longest ago first
    local due = {}
    for _, b in pairs(bays) do
        if b.due and b.state == "ready" then due[#due + 1] = b end
    end
    if #due > 0 then
        table.sort(due, function(x, y)
            local cx, cy = x.lastCap or -1, y.lastCap or -1
            if cx ~= cy then return cx < cy end
            return x.i < y.i
        end)
        for k = 1, math.min(#due, math.max(1, int("SetupPreviewCaptureBudget", 1))) do capture(due[k], now) end
    end
    -- 0.12.0 V-FIN-05: at most one backdrop corner read per tick (a GPU readback), once per bay
    for _, b in pairs(bays) do
        if b.calibDue then
            local ok, err = xpcall(calibrate, debug.traceback, b)
            if not ok then
                b.calibDue = false
                U.dbg(TAG, "bay %d corner read error: %s", b.i, tostring(err))
            end
            break
        end
    end
    local changed = next(keys) ~= nil
    for i, b in pairs(bays) do
        if sig(b) ~= before[i] then keys[i], changed = true, true end
    end
    return changed, keys
end

-- Key i's bay goes (its player left). freeTarget: the caller took the render off its image first.
function M.release(i, why, freeTarget)
    modes[i], capEvery[i] = nil, nil
    local b = bays[i]
    if not b then return end
    bays[i] = nil
    local n = destroyActor(b, "veh") + dropPlanes(b) + destroyActor(b, "fill") + destroyActor(b, "cap")
    if freeTarget and U.ok(b.rt) then pcall(function() U.cdo(KRL):ReleaseRenderTarget2D(b.rt) end) end
    b.rt, b.mid = nil, nil
    record()
    if n > 0 then U.log(TAG, "bay %d released (%s): %d actor(s) destroyed (V-VP-07)", i, tostring(why), n) end
end

-- Every bay goes (step left, setup closed, menu replaced, broken, phase). Game thread.
function M.releaseAll(why, freeTargets)
    pendingRelease = nil
    local nb, na = 0, 0
    for _, b in pairs(bays) do
        nb = nb + 1
        na = na + destroyActor(b, "veh") + dropPlanes(b) + destroyActor(b, "fill") + destroyActor(b, "cap")
        if freeTargets and U.ok(b.rt) then pcall(function() U.cdo(KRL):ReleaseRenderTarget2D(b.rt) end) end
        b.rt, b.mid = nil, nil
    end
    bays, lastTick, modes, capEvery = {}, nil, {}, {}
    record()
    if nb > 0 then
        U.log(TAG, "released (%s): %d bay(s), %d actor(s) destroyed; session %d spawn(s), %d rebuild(s), %d ready, "
            .. "%d failed, %d capture(s), %d still burst(s), %d build(s) spaced by the gap (V-VP-07, V-RC-17)",
            tostring(why), nb, na, stats.spawns, stats.rebuilds, stats.ready, stats.failed, stats.captures,
            stats.bursts, stats.gapWaits)
    end
end

-- 0.12.0 launch hold (state.lua St.launchHold): the bays' actors go with the front-end world being torn down; the
-- references are dropped and nothing is called on them.
function M.dropAll(why)
    pendingRelease = nil
    local nb = 0
    for _ in pairs(bays) do nb = nb + 1 end
    bays, lastTick, modes = {}, nil, {}
    record()
    if nb > 0 then
        U.log(TAG, "dropped (%s): %d bay(s), their actors go with the front-end world (launch hold, V-LCH-07)",
            tostring(why), nb)
    end
end

-- Counters for diag / test commands (V-RC-17), a new table per call: captures (session), capturesPerSec (the last
-- 10 s; a run that started later counts from its start, at least 1 s), spawns, rebuilds, ready, failed, gapWaits
-- (builds that waited for SetupPreviewSpawnGapMs), bursts (still bursts armed), bays, spin, still (bays per mode);
-- 0.12.0: backdrop (the rung in use now), planes (backdrop planes spawned), calibrations (corner reads, V-FIN-05).
function M.stats()
    local now = St.nowMs()
    local k = capFirst
    while k <= #capLog and now - capLog[k] > CAPS_WINDOW_MS do k = k + 1 end
    local n = #capLog - k + 1
    local span = math.max(1000, math.min(CAPS_WINDOW_MS, now - (capSince or now)))
    local s = { captures = stats.captures, capturesPerSec = n * 1000 / span, spawns = stats.spawns,
                rebuilds = stats.rebuilds, ready = stats.ready, failed = stats.failed, gapWaits = stats.gapWaits,
                bursts = stats.bursts, bays = 0, spin = 0, still = 0, backdrop = rungNow(), planes = stats.planes,
                calibrations = stats.calibrations, liveries = stats.liveries or 0 }
    for _, b in pairs(bays) do
        local m = modeOf(b)
        s.bays, s[m] = s.bays + 1, s[m] + 1
    end
    return s
end

-- One line for diag / test commands: bays as key=state:mode:pick:backdrop; 0.12.0 "backdrop <asked>[ -> <in use>]".
function M.status()
    local parts = {}
    for i, b in pairs(bays) do
        parts[#parts + 1] = string.format("%s=%s:%s:%s:%s", tostring(i), b.state, modeOf(b), tostring(b.applied),
            tostring(b.rung or "-"))
    end
    table.sort(parts)
    local asked, now = askedRung(), rungNow()
    return string.format("3D %s, backdrop %s, bays {%s}, captures %d (%.1f/s), spawns %d",
        broken and ("off: " .. broken) or "on", asked == now and now or (asked .. " -> " .. now),
        table.concat(parts, " "), stats.captures, M.stats().capturesPerSec, stats.spawns)
end

---------------------------------------------------------------------------------------------------- lifetime
-- A new world: the bay actors died with the old one (no game call here); targets and MIDs are not world objects.
St.on("world", TAG, function()
    if next(bays) == nil then return end
    local n = 0
    for _ in pairs(bays) do n = n + 1 end
    bays, lastTick, pendingRelease = {}, nil, nil
    record()
    U.log(TAG, "new world: %d bay(s) dropped with the old one (V-VP-07)", n)
end)

-- Safety net (lobby.lua closes the setup on a phase change, which releases): never a bay outside the front end.
St.on("phase", TAG, function(new)
    outside = {}                                           -- 4-way garage: a grant holds for one phase only
    if new ~= "FRONTEND" and next(bays) ~= nil then
        if St.launchHold() then M.dropAll("phase " .. tostring(new)) else M.releaseAll("phase " .. tostring(new)) end
    end
end)

-- Hot reload without main.lua's PERSIST_MODULES: the previous Lua state's actors, if any.
adoptOrphans(sharedGet(), "shared variable")

return M
