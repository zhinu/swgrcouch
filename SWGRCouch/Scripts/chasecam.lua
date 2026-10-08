-- chasecam.lua (0.6.0, 2026-10-07): a proper chase view of ANOTHER car for a wrecked local player (wreck.lua,
-- cfg.WreckView "car"/"carAll"). No init, no tick: wreck.lua calls it (require), so main.lua needs no wiring.
--
-- Run G (F3, g-w3-sheet.png / g-w-fix.png, UE4SS-123943.log 10:37:24 "P2 view -> Griff Halloran's car, AI"):
-- SetViewTargetWithBlend(<an AI pod>) put P2's camera INSIDE the pod, beside its engine, looking ahead. Static facts
-- (work/runtime/idx/types.json): AVehiclePawn has ONE camera, CameraComponent (UFuseCameraComponent; the vehicle's
-- UVehicleCameraComponent, a camera-mode STACK: GetActiveStackName()); AFuseCameraManager:FindCameraComponent(Actor)
-- renders a view target through that component. A car driven by a local human runs its stack (its owner's camera
-- manager evaluates it every frame: the chase camera P1/P2 see while driving); an AI car's component has no running
-- stack, so the POV is the component's raw transform at the pod's root: "camera in the engine".
--
-- What this module offers (cfg.WreckCarCam):
--   "auto" (default): a local human's car is watched through its own camera (a live chase camera); another car whose
--     camera runs no stack (inactive, GetActiveStackName() None) through a RIG at once; any other car through its own
--     camera while the placement check below passes (wreck.lua verifyStep), else through the RIG;
--   "rig": every watched car (not the player's own wreck) through a rig;
--   "car": the car itself, unchecked (0.5.1 behaviour).
-- RIG: one engine ACameraActor per wrecked player, spawned with GameplayStatics:BeginDeferredActorSpawnFromClass +
--   FinishSpawningActor, teleported cfg.WreckRigBackUU behind and cfg.WreckRigUpUU above the watched car (looking
--   down cfg.WreckRigPitch degrees along the car's heading) and attached to it with K2_AttachToActor (KeepWorld): the
--   engine moves it with the car every frame (a locked chase camera, no 33 ms stepping). Re-used for the next car
--   (K2_DetachFromActor + teleport + attach), destroyed (K2_DestroyActor) when the wreck view ends.
-- PLACEMENT CHECK (M.placement): the wrecked player's camera location against the watched car: closer than
--   cfg.WreckCarCamMinDistUU (300) = "inside", not at least cfg.WreckCarCamBehindUU (150) behind it along the car's
--   forward vector = "front" (run G's engine view), farther than WreckCamMaxDistUU = "far", else "chase".
-- Only reflected UFunctions are called (types.json): GameplayStatics BeginDeferredActorSpawnFromClass(World, Class,
-- Transform, ESpawnActorCollisionHandlingMethod, Owner, ESpawnActorScaleMethod) / FinishSpawningActor(Actor,
-- Transform, ESpawnActorScaleMethod), Actor K2_TeleportTo(Vector, Rotator), K2_AttachToActor(Actor, Name,
-- EAttachmentRule x3, Bool), K2_DetachFromActor(EDetachmentRule x3), K2_DestroyActor(), GetActorForwardVector(),
-- CameraComponent SetFieldOfView(Float) / SetConstraintAspectRatio(Bool), FuseCameraComponent GetActiveStackName(),
-- ActorComponent IsActive(). No soft pointers, no hooks.

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "chasecam"

local ATTACH_KEEP_WORLD = 1             -- EAttachmentRule::KeepWorld (KeepRelative 0, SnapToTarget 2)
local DETACH_KEEP_WORLD = 1             -- EDetachmentRule::KeepWorld
local SPAWN_ALWAYS = 1                  -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn
local SCALE_MULTIPLY = 1                -- ESpawnActorScaleMethod::MultiplyWithRoot

local rigs = {}                         -- [pcKey] = { actor, car, gen }
local broken = nil                      -- why the rig failed (session-wide: no retry loop)

local function opt(v, allowed, default)
    for _, a in ipairs(allowed) do if v == a then return v end end
    return default
end
local function num(v, d)
    local n = tonumber(v)
    if n == nil then return d end
    return n
end

function M.mode() return opt(cfg.WreckCarCam, { "auto", "own", "override", "rig", "car" }, "auto") end
function M.rigBroken() return broken end

local function vec3(v)
    if v == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y and z then return x, y, z end
    return nil
end

local function call0(o, fn)
    if o == nil then return nil end
    local ok, v = pcall(function() return o[fn](o) end)
    if ok then return v end
    return nil
end

-- The car's own camera component: comp, "active/stack" text (for the "view ->" lines; V-WD-19), live: false when the
-- component is inactive or runs no camera stack (GetActiveStackName() None/empty), true when it runs one, nil unknown.
function M.ownCamInfo(car)
    if not U.ok(car) then return nil, "no car", nil end
    local comp
    pcall(function() comp = car.CameraComponent end)          -- AVehiclePawn.CameraComponent (FuseCameraComponent)
    if not U.ok(comp) then return nil, "no CameraComponent", false end
    local active, stack
    pcall(function() active = comp:IsActive() end)
    pcall(function() stack = comp:GetActiveStackName():ToString() end)
    local live = nil
    if active == false or stack == "None" or stack == "" then live = false
    elseif active == true and type(stack) == "string" then live = true end
    return comp, string.format("cam active=%s stack=%s", tostring(active), tostring(stack)), live
end

-- Where the pc's camera sits relative to car: verdict, dist, along (negative = behind), height.
function M.placement(pc, car)
    local pcm
    pcall(function() pcm = pc.PlayerCameraManager end)
    if not (U.ok(pcm) and U.ok(car)) then return "unknown" end
    local cx, cy, cz = vec3(call0(pcm, "GetCameraLocation"))
    local lx, ly, lz = vec3(call0(car, "K2_GetActorLocation"))
    local fx, fy, fz = vec3(call0(car, "GetActorForwardVector"))
    if not (cx and lx and fx) then return "unknown" end
    if cx ~= cx or cy ~= cy or cz ~= cz then return "inside", 0, 0, 0 end      -- NaN camera
    local dx, dy, dz = cx - lx, cy - ly, cz - lz
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local along = dx * fx + dy * fy + dz * fz
    if dist < num(cfg.WreckCarCamMinDistUU, 300) then return "inside", dist, along, dz end
    if along > -num(cfg.WreckCarCamBehindUU, 150) then return "front", dist, along, dz end
    if dist > num(cfg.WreckCamMaxDistUU, 15000) then return "far", dist, along, dz end
    return "chase", dist, along, dz
end

-- Rig pose for car: location behind/above the car along its heading, rotation (yaw of the heading, pitch down).
local function rigPose(car)
    local lx, ly, lz = vec3(call0(car, "K2_GetActorLocation"))
    local fx, fy = vec3(call0(car, "GetActorForwardVector"))
    if not (lx and fx) then return nil end
    local h = math.sqrt(fx * fx + fy * fy)
    if h < 0.05 then fx, fy, h = 1, 0, 1 end                    -- car pointing straight up/down: any heading
    fx, fy = fx / h, fy / h
    local back, up = num(cfg.WreckRigBackUU, 900), num(cfg.WreckRigUpUU, 260)
    local loc = { X = lx - fx * back, Y = ly - fy * back, Z = lz + up }
    local rot = { Pitch = -num(cfg.WreckRigPitch, 10), Yaw = math.deg(math.atan(fy, fx)), Roll = 0.0 }
    return loc, rot
end

local function spawnRig(car)
    local cls = U.class("/Script/Engine.CameraActor")
    local gsl, world = U.GS(), U.world()
    if not (U.ok(cls) and U.ok(gsl) and U.ok(world)) then return nil, "CameraActor/GameplayStatics/world missing" end
    local loc = rigPose(car)
    if not loc then return nil, "car location unreadable" end
    local T = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = loc,
                Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local a
    local ok, err = pcall(function()
        a = gsl:BeginDeferredActorSpawnFromClass(world, cls, T, SPAWN_ALWAYS, nil, SCALE_MULTIPLY)
        if U.ok(a) then gsl:FinishSpawningActor(a, T, SCALE_MULTIPLY) end
    end)
    if not ok then return nil, "spawn error " .. tostring(err) end
    if not U.ok(a) then return nil, "spawn returned no actor" end
    pcall(function()
        local cc = a.CameraComponent
        -- 0.7.2 (research guest-camera-black.md): the game's DefaultEngine.ini sets
        -- r.CinematicCamera.ConstrainAspectRatioUsingPostProcess=True, so every camera actor gets a post-process
        -- letterbox (M_PP_CameraLetterboxing) whose 16:9 rect is in ABSOLUTE screen pixels: P1 (top) saw a pillarbox,
        -- P2's lower half lay outside the mask and rendered BLACK. Clearing the flag removes the blendable natively.
        pcall(function() cc:SetConstrainAspectRatioUsingPostProcess(false) end)
        cc:SetConstraintAspectRatio(false)                    -- a split half is ~3.5:1: no letterbox bars
        cc:SetFieldOfView(num(cfg.WreckRigFov, 85))
        local okF, pp = pcall(function() return cc:GetConstraintAspectRatioUsingPostProcess() end)
        U.log(TAG, "rig camera letterbox post-process %s (V-GCB-02)", (okF and pp == false) and "off" or
            ("still on? " .. tostring(pp)))
    end)
    return a
end

-- Puts the rig of pc behind car (spawned on first use) and returns it, or nil, why.
-- VERIFY(V-WD-20): "rig on <car>" line, then the wrecked half shows that car from behind/above, following it smoothly.
function M.rigFor(pc, car)
    if broken then return nil, "rig broken earlier: " .. broken end
    if not (U.ok(pc) and U.ok(car)) then return nil, "no pc/car" end
    local k = U.key(pc)
    local r = rigs[k]
    if r and (r.gen ~= St.worldGen or not U.ok(r.actor)) then r = nil end
    local spawned = false
    if not r then
        local a, why = spawnRig(car)
        if not a then
            broken = why
            U.warn(TAG, "chase rig unavailable (%s): watched cars are shown through their own camera (V-WD-20)", why)
            return nil, why
        end
        r = { actor = a, gen = St.worldGen }
        rigs[k], spawned = r, true
    end
    if U.ok(r.car) and not U.same(r.car, car) then
        pcall(function() r.actor:K2_DetachFromActor(DETACH_KEEP_WORLD, DETACH_KEEP_WORLD, DETACH_KEEP_WORLD) end)
    end
    if not U.same(r.car, car) then
        local loc, rot = rigPose(car)
        if not loc then return nil, "car location unreadable" end
        local okT = pcall(function() r.actor:K2_TeleportTo(loc, rot) end)
        local okA, att = pcall(function()
            return r.actor:K2_AttachToActor(car, U.fname("None"), ATTACH_KEEP_WORLD, ATTACH_KEEP_WORLD,
                ATTACH_KEEP_WORLD, false)
        end)
        if not (okT and okA and att ~= false) then
            local why = string.format("teleport %s attach %s", tostring(okT), tostring(att))
            pcall(function() r.actor:K2_DestroyActor() end)
            rigs[k], broken = nil, why
            U.warn(TAG, "chase rig could not follow the car (%s): rig off for the session (V-WD-20)", why)
            return nil, why
        end
        r.car = car
        U.log(TAG, "rig %s for %s: %.0f uu behind, %.0f up, pitch -%.0f, fov %.0f", spawned and "spawned" or "moved",
            U.pathOf(pc), num(cfg.WreckRigBackUU, 900), num(cfg.WreckRigUpUU, 260), num(cfg.WreckRigPitch, 10),
            num(cfg.WreckRigFov, 85))
    end
    return r.actor
end

function M.isRig(actor)
    if not U.ok(actor) then return false end
    for _, r in pairs(rigs) do
        if U.same(r.actor, actor) then return true end
    end
    return false
end

-- The rig of pc is destroyed (the wreck view ended / the view went back to a car's own camera).
function M.release(pc, why)
    local k = U.ok(pc) and U.key(pc) or pc
    local r = rigs[k]
    if not r then return end
    rigs[k] = nil
    if U.ok(r.actor) then
        pcall(function() r.actor:K2_DestroyActor() end)
        U.dbg(TAG, "rig released (%s)", tostring(why))
    end
end

function M.releaseAll(why)
    for k in pairs(rigs) do M.release(k, why) end
    rigs = {}
    M.releaseOverrideAll(why)
end

-- 0.7.1 OVERRIDE (run I, 2026-10-07): a guest's view through ANY camera actor (this rig, the game's crash camera)
-- renders BLACK in the lower split view: the Fuse camera manager constrains the aspect ratio of non-vehicle cameras
-- (P1 sees the same rig pillarboxed; the rig's own bConstrainAspectRatio reads false), and the constrained rect of the
-- second view lands nowhere. AI pods have no camera component at all. Proven live: the wrecked player's OWN pod camera
-- (UFuseCameraComponent, a running camera-mode stack) with TargetActorOverride = the watched car renders a normal
-- following view in P2's half. The view target stays the player's own car. (Run J correction: the
-- 'self-pause' first blamed on this override was the game's 60 s inactivity auto-pause of idle test pads.)
local overrides = {}                    -- [pcKey] = { car = own car, target }

function M.overrideFor(pc, ownCar, target)
    if not (U.ok(pc) and U.ok(ownCar) and U.ok(target)) then return nil, "no pc/own car/target" end
    local comp
    pcall(function() comp = ownCar.CameraComponent end)
    if not U.ok(comp) then return nil, "own car has no CameraComponent" end
    local ok, err = pcall(function() comp.TargetActorOverride = target end)
    if not ok then return nil, "TargetActorOverride write failed: " .. tostring(err) end
    local k = U.key(pc)
    local prev = overrides[k]
    overrides[k] = { car = ownCar, target = target }
    if not (prev and U.same(prev.target, target)) then
        U.log(TAG, "own camera of %s follows %s (TargetActorOverride) (V-WD-21)", ownCar:GetFName():ToString(),
            target:GetFName():ToString())
    end
    return ownCar
end

function M.isOverride(pc)
    local k = U.ok(pc) and U.key(pc) or pc
    return overrides[k] ~= nil
end

function M.releaseOverride(pc, why)
    local k = U.ok(pc) and U.key(pc) or pc
    local o = overrides[k]
    if not o then return end
    overrides[k] = nil
    if U.ok(o.car) then
        pcall(function() o.car.CameraComponent.TargetActorOverride = nil end)
        U.dbg(TAG, "own camera override released (%s)", tostring(why))
    end
end

function M.releaseOverrideAll(why)
    for k in pairs(overrides) do M.releaseOverride(k, why) end
    overrides = {}
end

return M
