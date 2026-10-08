-- vpreview.lua (0.7.2, 2026-10-07): a live 3D render of each RACE SETUP vehicle pick ("photo bays"), front end only.
-- Design: notes/research/vehicle-preview.md (§3 design, §4 recipe, §6 risks, §7 VERIFY V-VP-01..07). setup.lua drives
-- it (no init, no loop of its own): want() and brush() from renderColumns, tick() from its FAST pollNav while the
-- VEHICLES step shows, release()/releaseAll() when a column goes, the step is left, the setup closes or the menu is
-- replaced. No hooks, no FindAllOf, no soft pointers: every call below is a reflected UFunction / property
-- (work/runtime/UE4SS_ObjectDump.txt, signatures checked 2026-10-07).
--
-- One bay per column, in the empty sky above the front-end sets (SetupPreviewX/Y/Z + (column - 1) * Spacing):
--   * the model: GfnGameInstance.StaticVehicleClass (BP_StaticVehicleBase_C, an ACstStaticVehicle) spawned deferred
--     with `preset` = the pick's PRE_* class: the game's own SpawnFrontEndVehicle path, the spawn builds the model.
--     A new pick (after SetupPreviewDebounceMs) spawns a fresh actor (SetupPreviewRebuild "respawn": the unit count
--     restarts at 0, so "built" is unambiguous) or rewrites `preset` + UpdateCustomisationMesh() ("update", V-VP-02);
--   * the camera: an engine SceneCapture2D (show-only list = the model; bCaptureEveryFrame off, CaptureScene() from
--     this module only, so nothing keeps rendering after a reload) into a TextureRenderTarget2D. RGBA16f: a float
--     target gets display gamma 1, the tonemapper writes linear colour and the UI shows the right gamma;
--   * an optional fill PointLight beside the camera (SetupPreviewFillLux at the model, no shadows, Movable).
-- "Built" = CustomisationComponent:GetUnitContainerCount() > 0 and the yaw-0 bounds equal on two samples 100 ms
-- apart; then the camera is framed from the bounds, the show-only list and the framing are refreshed for 2.5 s (late
-- parts), the model turns about its bounds centre (SetupPreviewSpinDps) and CaptureScene() runs every
-- SetupPreviewCaptureMs (spin 0: at ready, +0.5 s, +2 s, +5 s, then every 5 s).
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
local DIM = 0.5                             -- alpha of the previous model's render while the new pick builds
local ZERO_ROT = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }

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

local bays = {}            -- [column] = bay (see newBay)
local broken = nil         -- session-wide reason: 2D cards only
local pendingRelease = nil -- markBroken inside a tick: everything goes at the end of that tick
local recorded = ""        -- actor paths last written to the shared variable
local orphans = nil        -- hot reload: the previous Lua state's actor paths (destroyed on the game thread)
local lastTick = nil
local verbose = 0          -- per-pick lines at INFO for the first builds of the session, then dbg
local stats = { spawns = 0, rebuilds = 0, ready = 0, failed = 0, captures = 0 }

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
        for _, k in ipairs({ "veh", "cap", "fill" }) do
            if b.path[k] then parts[#parts + 1] = b.path[k] end
        end
    end
    local s = table.concat(parts, "|")
    if s ~= recorded then
        recorded = s
        sharedPut(s)
    end
end

-- One of ours: a static vehicle / capture / light of the current world, far above the sets (never the game's).
local function isBayActor(a)
    if not (U.isA(a, VEH_NATIVE) or U.isA(a, CAPTURE) or U.isA(a, LIGHT)) then return false end
    local okW, w = pcall(function() return a:GetWorld() end)
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
local function origin(i)
    return { X = num("SetupPreviewX", 0) + (i - 1) * num("SetupPreviewSpacing", 5000),
             Y = num("SetupPreviewY", 60000), Z = num("SetupPreviewZ", 60000) }
end

local function newBay(i)
    return { i = i, O = origin(i), gen = St.worldGen, wk = U.key(U.world()), path = {}, state = "idle",
             shown = false, everReady = false }
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

-- Destroys bay actor k ("veh" | "cap" | "fill") when it belongs to the current world. Returns 1 when destroyed.
local function destroyActor(b, k)
    local a = b[k]
    b[k], b.path[k] = nil, nil
    if k == "cap" then b.comp = nil end
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
    b.state, b.applied, b.shown = "failed", id, false
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
    local w, h, fmt = int("SetupPreviewW", 640), int("SetupPreviewH", 360), int("SetupPreviewRtFormat", 6)
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
    b.rt = rt
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
    local ok, got = pcall(function() return veh.preset end)
    if not ok then return false, "unreadable" end
    if U.same(got, cls) then return true end
    local n = "None"
    pcall(function() n = got:GetFName():ToString() end)
    return false, n
end

local function say(f, ...)
    if verbose <= 8 then U.log(TAG, f, ...) else U.dbg(TAG, f, ...) end
end

-- The newest pick w of bay b goes into the model (tickBay debounces).
local function apply(b, w, now)
    if not ensureInfra(b) then return end
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
    verbose = verbose + 1
    say("bay %d: %s %s (%s, archetype %d) (V-VP-%s)", b.i, w.id, how, tostring(w.p.name), w.arch, update and "02" or "01")
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
    local vHalf = math.atan(math.tan(hHalf) / (num("SetupPreviewW", 640) / num("SetupPreviewH", 360)))
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
end

local function showOnly(b)
    if opt("SetupPreviewShowOnly", true) == false then return end
    pcall(function()
        b.comp:ClearShowOnlyComponents()
        b.comp:ShowOnlyActorComponents(b.veh, true)        -- UFunctions: never write the TArray from Lua
    end)
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

local function capture(b, now)
    if pcall(function() b.comp:CaptureScene() end) then stats.captures = stats.captures + 1 end
    b.lastCap, b.capN = now, (b.capN or 0) + 1
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
    b.shown, b.everReady = true, true
    capture(b, now)
    stats.ready = stats.ready + 1
    local E = box.E
    say("bay %d ready: %s, %s unit(s), %s bounds %.0fx%.0fx%.0f (r %.0f), camera %.0f uu, %d ms, %s (V-VP-01)", b.i,
        tostring(b.applied), tostring(box.count), tostring(box.kind), 2 * E.X, 2 * E.Y, 2 * E.Z, box.r, b.dist or 0,
        math.floor(now - b.since), how)
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
local function dropCheck(b, now)
    if now < (b.nextDrop or 0) then return end
    b.nextDrop = now + 500
    local p = vec(function() return b.veh:K2_GetActorLocation() end)
    if not p or p.Z >= b.pivot.Z - 50 then return end
    U.logOnce("vpreview.drop", TAG, "bay %d: the model falls (z %.0f < %.0f): physics off, put back (V-VP-01)", b.i,
        p.Z, b.pivot.Z)
    pcall(function() b.veh.CstRootComponent:SetSimulatePhysics(false) end)
    spinTo(b, b.yaw)
end

local function runReady(b, now, dt)
    if not (U.ok(b.veh) and U.ok(b.comp)) then return failBay(b, b.applied, "a bay actor vanished") end
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
    dropCheck(b, now)
    local dps, due = num("SetupPreviewSpinDps", 15), false
    if dps ~= 0 then
        b.yaw = (b.yaw + dps * dt / 1000) % 360
        spinTo(b, b.yaw)
        local every = num("SetupPreviewCaptureMs", 50)
        due = every <= 0 or now - (b.lastCap or 0) >= every
    else
        local at = STATIC_CAPS[(b.capN or 0) + 1]
        if at then due = age >= at else due = now - (b.lastCap or 0) >= 5000 end
    end
    if due then capture(b, now) end
end

local function tickBay(b, now, dt)
    local w = b.want
    if w and w.id ~= b.applied and now - w.at >= int("SetupPreviewDebounceMs", 250) then apply(b, w, now) end
    if broken then return end
    if b.state == "building" then checkBuild(b, now)
    elseif b.state == "ready" then runReady(b, now, dt) end
end

---------------------------------------------------------------------------------------------------- API (setup.lua)
-- false, why when no 3D preview can be shown (setting off, broken, outside the front end).
function M.enabled()
    if opt("SetupPreview3D", true) == false then return false, "SetupPreview3D = false" end
    if broken then return false, broken end
    if St.phase ~= "FRONTEND" then return false, "phase " .. tostring(St.phase) end
    return true
end

function M.aspect() return num("SetupPreviewW", 640) / num("SetupPreviewH", 360) end

-- Column i shows preset entry p (vehicles.presets) of class entry cls. Idempotent: the build starts in tick() once
-- the pick has not changed for SetupPreviewDebounceMs.
function M.want(i, p, cls)
    if not M.enabled() or type(p) ~= "table" or type(p.id) ~= "string" or type(cls) ~= "table" then return end
    local b = bays[i]
    if b and b.gen ~= St.worldGen then bays[i], b = nil, nil end
    if not b then
        b = newBay(i)
        bays[i] = b
    end
    if b.want and b.want.id == p.id then return end
    b.want = { id = p.id, p = p, arch = math.floor(tonumber(cls.arch) or 0), at = St.nowMs() }
end

-- What column i shows: brush, "material" | "texture", alpha multiplier, aspect; nil = the 2D card. The previous
-- model stays (dimmed) while a new pick builds. The MID is made here, in the tick that puts it on the image: an
-- object only Lua knows (no UPROPERTY reference) may be garbage collected.
function M.brush(i)
    if not M.enabled() then return nil end
    local b = bays[i]
    if not (b and b.shown and U.ok(b.rt)) then return nil end
    local dim = (b.state == "ready" and b.want ~= nil and b.want.id == b.applied) and 1.0 or DIM
    if opt("SetupPreviewBrush", "material") == "texture" then return b.rt, "texture", dim, M.aspect() end
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
    return b.mid, "material", dim, M.aspect()
end

-- FAST (setup.pollNav while the VEHICLES step shows). true = what a column shows changed (setup re-renders).
function M.tick()
    if pendingRelease then M.releaseAll(pendingRelease); return true end
    if next(bays) == nil then lastTick = nil; return false end
    local on, why = M.enabled()
    if not on then M.releaseAll(why); return true end
    local now = St.nowMs()
    local dt = lastTick and math.max(0, math.min(200, now - lastTick)) or 33
    lastTick = now
    local wk, changed = U.key(U.world()), false
    for i, b in pairs(bays) do
        if b.gen ~= St.worldGen or (b.wk ~= 0 and wk ~= 0 and b.wk ~= wk) then
            bays[i], changed = nil, true                   -- another world: the old one took the actors with it
        else
            local before = b.state .. "|" .. tostring(b.shown) .. "|" .. tostring(b.applied)
            local ok, err = xpcall(tickBay, debug.traceback, b, now, dt)
            if not ok then
                U.dbg(TAG, "bay %d tick error: %s", b.i, tostring(err))
                failBay(b, b.want and b.want.id or b.applied, "error: " .. tostring(err):match("^[^\n]*"))
            end
            if b.state .. "|" .. tostring(b.shown) .. "|" .. tostring(b.applied) ~= before then changed = true end
        end
    end
    if pendingRelease then
        M.releaseAll(pendingRelease)
        changed = true
    end
    return changed
end

-- Column i's bay goes (its player left). freeTarget: setup took the render off the column image first.
function M.release(i, why, freeTarget)
    local b = bays[i]
    if not b then return end
    bays[i] = nil
    local n = destroyActor(b, "veh") + destroyActor(b, "fill") + destroyActor(b, "cap")
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
        na = na + destroyActor(b, "veh") + destroyActor(b, "fill") + destroyActor(b, "cap")
        if freeTargets and U.ok(b.rt) then pcall(function() U.cdo(KRL):ReleaseRenderTarget2D(b.rt) end) end
        b.rt, b.mid = nil, nil
    end
    bays, lastTick = {}, nil
    record()
    if nb > 0 then
        U.log(TAG, "released (%s): %d bay(s), %d actor(s) destroyed; session %d spawn(s), %d rebuild(s), %d ready, "
            .. "%d failed, %d capture(s) (V-VP-07)", tostring(why), nb, na, stats.spawns, stats.rebuilds, stats.ready,
            stats.failed, stats.captures)
    end
end

-- One line for diag / test commands.
function M.status()
    local parts = {}
    for i, b in pairs(bays) do parts[#parts + 1] = string.format("%d=%s:%s", i, b.state, tostring(b.applied)) end
    table.sort(parts)
    return string.format("3D %s, bays {%s}, captures %d", broken and ("off: " .. broken) or "on",
        table.concat(parts, " "), stats.captures)
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
    if new ~= "FRONTEND" and next(bays) ~= nil then M.releaseAll("phase " .. tostring(new)) end
end)

-- Hot reload without main.lua's PERSIST_MODULES: the previous Lua state's actors, if any.
adoptOrphans(sharedGet(), "shared variable")

return M
