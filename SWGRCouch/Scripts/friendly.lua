-- SWGRCouch / friendly.lua  (couch-fix75, player request #12, 2026-10-24)
-- COUCH CAMPAIGN house rule "Friendly fire" (settings.txt CouchFriendlyFire, OPTIONS > COUCH CAMPAIGN):
--   "on"  (DEFAULT) = the game's own behaviour, as in solo: a human's abilities hit every other car, humans included.
--   "off" = the local human players are one team: an Ion Bolt / Multi-Bolt does not lock on a teammate, an Ion Blast /
--           Shockwave / attacking Vent overlap does not reach a teammate, a Shockwave push of a teammate has no
--           strength. AI cars are hit exactly as before, and the AI's abilities hit the humans exactly as before.
-- Only in couch campaign races (couch.active()) with 2+ local humans, PRERACE / RACING. Collisions (rams, a teammate
-- shoved into a wall by your car) stay the game's: not filtered (a ghosted teammate would change the race far more than
-- the request; instances.lua shows it could be done per pair of cars with the collision channels).
--
-- WHY THESE HOOK POINTS (static reflection of CL386500, galactic-racer/scripts/reflect-types.py + reflect-func.py):
--   * Ion Bolt / Multi-Bolt = AAbilityDisruptor <- ATargetingAbility <- AGfnAbility. The target choice is C++ only (no
--     UFunction): ATargetingAbility.TrackedTargets @+0x5c8 is a TArray<FTrackedTarget> {TrackedPlayer (AGfnPlayerState)
--     @+0, LockingOnTime @+8, OutOfSightTime @+0xc, IsInValidTargetingArea, TargetingState (EAbilityTargetState:
--     Invalid 0, LockingOn 1, FinishedLockingOn 2, RemoveTarget 3) @+0x11, LockingOnProgressNormalised @+0x14}, its lock
--     time UTargetingAbilityConfig.TimeUntilLockOn @+0x68 (Ion Bolt 2.5 s, Multi-Bolt 0.5 s, x0.5 improved use). Its
--     RepNotify OnTrackedTargetsUpdated never runs on the (local) server. So LAYER 1 (fastTick, every FAST tick): an entry
--     of a local human's targeting ability whose TrackedPlayer is ANOTHER local human gets its lock progress reset -
--     the lock on a teammate never finishes, the bolt is never fired at him. LockingOnTime is reset as an accumulator
--     (0) or, if the live values show it is a start time stamp (~ the world time), as a fresh stamp (now): the meaning is
--     detected on the first entry seen and logged (V-FF-01). cfg.CouchFriendlyFireLock "drop" also sets TargetingState
--     RemoveTarget (the game's own removal path: may make the lock beam flicker; "hold" is the default).
--     The single-target Ion Bolt still spends its slot on a teammate who is the closest car in the cone (the lock is
--     held, not moved to an AI): the game picks the target in C++ and no reflected data says which car comes next.
--   * Ion Blast = ACrashAbilityDischarge, Shockwaves, attacking Vents (Acid / Flame / Freezing) and punches hit through
--     an AAbilityOverlapHelper (mOwningVehicle @+0x2e8) whose AbilityOverlapStart(overlappedActor, otherActor) /
--     AbilityComponentOverlapStart(OverlappedComponent, OtherActor, OtherComp, ...) are the UFUNCTIONs bound to the
--     overlap delegates (dynamic delegates run through ProcessEvent: native hooks see them). LAYER 2 (pre-hooks): a
--     teammate as OtherActor is replaced by the helper's OWN car (cfg.CouchFriendlyFireOverlapSwap "owner", default):
--     a car its own helper always overlaps (the helper sits on it), so the game's own "not my owner" path drops it and
--     the parameter stays a real VehiclePawn (no cast of a non-vehicle). "self" = the helper actor instead. The END
--     overlaps are left alone (a teammate that never began is never in mVehiclesCurrentlyAffectedByAttack).
--     [instances.lua: UE4SS param :set() in a native pre-hook reaches the body - live V-INST-PUSH "Strength -> 0 ok"]
--   * A Shockwave's push = AbilityShockwaveSource:Multi_AddVehicle(vehiclePawn, strength): a teammate's push -> 0.
--   * NOT FILTERABLE: mines (AProximityMine: its blast applies to every car in its EffectArea from C++; OnExplode /
--     Multi_Explode only report it), ramming / collision damage, and a teammate's crash caused by an AI.
-- LEAK DETECTION (so a live test can tell which layer works): AbilityDisruptor:Multi_OnLockFinished(targetedPlayer) and
-- Multi_OnTargetsDisrupted(vehiclesDisrupted, vehiclesDeshielded), AbilityModular:Multi_OnOverlapStartEvent(OtherVehicle)
-- naming a teammate of the ability's human owner = a WARN "friendly hit got through" (V-FF-03). A race summary line
-- (V-FF-05) counts holds, swaps, zeroed pushes and leaks.
-- The hooks are registered the first time the rule is OFF in a race (an ON player pays nothing).

local cfg = require("config")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "friendly"
local fmt = string.format

M.RULES = { "on", "off" }
M.P_TARGETING = "/Script/Griffin.TargetingAbility"
M.P_ABILITY = "/Script/Griffin.GfnAbility"
M.P_HELPER = "/Script/Griffin.AbilityOverlapHelper"
M.P_FEEDBACK = "/Script/Griffin.AbilityFeedback"
M.P_VEHICLE = "/Script/Griffin.VehiclePawn"
M.HOOKS = {
    lockDone  = "/Script/Griffin.AbilityDisruptor:Multi_OnLockFinished",
    disrupted = "/Script/Griffin.AbilityDisruptor:Multi_OnTargetsDisrupted",
    ovStart   = "/Script/Griffin.AbilityOverlapHelper:AbilityOverlapStart",
    ovComp    = "/Script/Griffin.AbilityOverlapHelper:AbilityComponentOverlapStart",
    push      = "/Script/Griffin.AbilityShockwaveSource:Multi_AddVehicle",
    modular   = "/Script/Griffin.AbilityModular:Multi_OnOverlapStartEvent",
}
M.STATE_REMOVE = 3                      -- EAbilityTargetState::RemoveTarget
local RACE = { PRERACE = true, RACING = true }
local TEAM_TTL_MS, ABIL_TTL_MS = 500, 3000

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

--- the rule: "on" (default, the game's own) | "off" (teammates are not hit)
local settingsMod = nil
function M.rule()
    -- every FAST race tick asks: no closure, no pcall per call (couch-racegc garbage budget)
    if settingsMod == nil then
        local ok, m = pcall(require, "settings")
        settingsMod = (ok and type(m) == "table") and m or false
    end
    local v = nil
    if settingsMod then v = settingsMod.get("CouchFriendlyFire") end
    if v == nil then v = (type(cfg.Defaults) == "table" and cfg.Defaults.CouchFriendlyFire) or "on" end
    if v == "off" then return "off" end
    return "on"
end

---------------------------------------------------------------------------------------------------- per race state
local R = nil                                   -- { gen, stats, pairs, sem, logged, team, abil }
local function newRace()
    return { gen = St.worldGen, team = nil, abil = {}, logged = {},
             stats = { held = 0, dropped = 0, swaps = 0, pushes = 0, leaks = 0, skipped = 0 } }
end
local function race()
    if R == nil or R.gen ~= St.worldGen then R = newRace() end
    return R
end
M._race = race
local sem = nil                                 -- LockingOnTime meaning for the session: nil | "acc" | "stamp"
function M.semantics() return sem end
function M._setSemantics(v) sem = v end

local function couchActive()
    local cm = package.loaded["couch"]
    if type(cm) ~= "table" or type(cm.active) ~= "function" then return false end
    local ok, v = pcall(cm.active)
    return ok and v == true
end

-- the local humans of this race: ps key -> member, car key -> member. member = { pnum, ps, car, psKey, carKey }
local function buildTeam()
    local t = { at = St.nowMs(), byPs = {}, byCar = {}, list = {} }
    for i, e in ipairs(U.localPlayersRO()) do
        local pc = e.pc
        if U.ok(pc) then
            local ps, car = nil, nil
            pcall(function() ps = pc.PlayerState end)
            pcall(function() car = pc.Pawn end)
            if U.ok(ps) then
                local m = { pnum = i, ps = ps, psKey = U.key(ps), car = nil, carKey = 0 }
                if U.ok(car) and U.isVehicle(car) then m.car, m.carKey = car, U.key(car) end
                t.list[#t.list + 1] = m
                t.byPs[m.psKey] = m
                if m.carKey ~= 0 then t.byCar[m.carKey] = m end
            end
        end
    end
    return t
end
function M.team()
    local r = race()
    local t = r.team
    if t == nil or St.nowMs() - t.at >= TEAM_TTL_MS then
        t = buildTeam()
        r.team = t
    else
        -- kept: re-check the wrappers it hands out (a car respawned after a wreck is a new pawn: rebuilt below)
        for _, m in ipairs(t.list) do
            if not U.ok(m.ps) or (m.car ~= nil and not U.ok(m.car)) then t = buildTeam(); r.team = t; break end
        end
    end
    return t
end

--- the rule applies right now (cheap first: the setting, then the phase, then the campaign and the team)
function M.enabledNow()
    if M.rule() ~= "off" then return false end
    if not RACE[St.phase] then return false end
    if opt("CouchFriendlyFireAnyRace", false) ~= true and not couchActive() then return false end
    return #M.team().list >= 2
end

local function pname(m) return m and ("P" .. tostring(m.pnum)) or "?" end

-- the human member who owns `o` (a VehiclePawn, an AGfnPlayerState, an ability, its overlap helper or feedback, or an
-- actor owned by one of those, up to 3 GetOwner hops) -> member | nil
function M.ownerOf(o, t)
    t = t or M.team()
    if type(o) == "table" and type(o.get) == "function" then o = o:get() else o = U.unwrap(o) end
    for _ = 1, 4 do
        if not U.ok(o) then return nil end
        local k = U.key(o)
        if t.byCar[k] then return t.byCar[k] end
        if t.byPs[k] then return t.byPs[k] end
        local nxt = nil
        if U.isA(o, M.P_HELPER) then
            pcall(function() nxt = o.mOwningVehicle end)
        elseif U.isA(o, M.P_ABILITY) then
            pcall(function() nxt = o.OwningPlayer end)
        elseif U.isA(o, M.P_FEEDBACK) then
            pcall(function() nxt = o.ParentAbility end)
        else
            pcall(function() nxt = o:GetOwner() end)
        end
        o = nxt
    end
    return nil
end

local function bump(r, key, line, ...)
    r.stats[key] = r.stats[key] + 1
    if line and not r.logged[line] then
        r.logged[line] = true
        U.log(TAG, ...)
    end
end

---------------------------------------------------------------------------------------------------- layer 1: locks
local function gameTime()
    local v = nil
    pcall(function() v = tonumber(U.GS():GetTimeSeconds(U.world())) end)
    return v
end

local function lockTimeOf(ab, r)
    local k = U.key(ab)
    local e = r.abil[k]
    if e and e.lockT then return e.lockT end
    local v = nil
    pcall(function() v = tonumber(ab.AbilityConfig.TimeUntilLockOn) end)
    if not v or v <= 0 then v = 2.5 end
    if e then e.lockT = v end
    return v
end

-- decide what LockingOnTime means from one live value (see the header). -> "acc" | "stamp" | nil (not yet decidable)
function M.decideSemantics(lt, lockT, now)
    if type(lt) ~= "number" or type(lockT) ~= "number" then return nil end
    if lt <= lockT + 0.5 then return "acc" end
    if type(now) == "number" and lt > lockT + 1 and math.abs(now - lt) <= lockT + 1 then return "stamp" end
    return nil
end

-- one tracked entry of `ab` (owned by member `m`) that points at teammate `tm`
local function holdEntry(e, ab, m, tm, r)
    local lt = nil
    pcall(function() lt = tonumber(e.LockingOnTime) end)
    if lt == nil then return end
    local lockT = lockTimeOf(ab, r)
    local now = nil
    if sem == nil then
        now = gameTime()
        local s = M.decideSemantics(lt, lockT, now)
        if s == nil then
            if lt > 0 then
                bump(r, "skipped", "undecided", "WARN friendly fire OFF: %s's %s locks on %s with LockingOnTime %.3f "
                    .. "(lock %.2f s, world time %s): neither a lock timer nor a time stamp - not touched (V-FF-01)",
                    pname(m), U.className(ab), pname(tm), lt, lockT, tostring(now))
            end
            return
        end
        sem = s
        U.log(TAG, "friendly fire OFF: LockingOnTime reads as %s (%.3f, lock %.2f s, world time %s) (V-FF-01)",
            s == "acc" and "a lock TIMER (reset to 0)" or "a lock START STAMP (reset to now)", lt, lockT, tostring(now))
    end
    local okW
    if sem == "stamp" then
        now = now or gameTime()
        if now == nil then return end
        okW = pcall(function() e.LockingOnTime = now end)
    else
        okW = pcall(function() e.LockingOnTime = 0.0 end)
    end
    pcall(function() e.LockingOnProgressNormalised = 0.0 end)
    local drop = opt("CouchFriendlyFireLock", "hold") == "drop"
    if drop then pcall(function() e.TargetingState = M.STATE_REMOVE end) end
    bump(r, drop and "dropped" or "held", "lock" .. m.pnum .. ">" .. tm.pnum,
        "friendly fire OFF: %s's %s was locking on teammate %s: lock %s (%s, lock %.2f s) (V-FF-01)", pname(m),
        U.className(ab), pname(tm), drop and "dropped" or "held at 0", okW and "ok" or "WRITE FAILED", lockT)
end

-- the targeting abilities of member m (AbilityComponent.Abilities that are ATargetingAbility), cached ABIL_TTL_MS
local function targetingOf(m, r)
    local c = r.abil[m.psKey .. ":list"]
    local now = St.nowMs()
    if c and now - c.at < ABIL_TTL_MS then return c.list end
    local list = {}
    pcall(function()
        local arr = m.ps.AbilityComponent.Abilities
        for i = 1, U.arrayCount(arr) do
            local a = nil
            pcall(function() a = arr[i] end)
            if U.ok(a) and U.isA(a, M.P_TARGETING) then
                list[#list + 1] = a
                local k = U.key(a)
                if not r.abil[k] then r.abil[k] = { lockT = nil } end
            end
        end
    end)
    r.abil[m.psKey .. ":list"] = { at = now, list = list }
    return list
end
M._targetingOf = targetingOf

local function scanAbility(ab, m, t, r)
    local arr = nil
    pcall(function() arr = ab.TrackedTargets end)
    local n = U.arrayCount(arr)
    for i = 1, n do
        local e = nil
        pcall(function() e = arr[i] end)
        if e ~= nil then
            local tp = nil
            pcall(function() tp = e.TrackedPlayer end)
            local k = U.ok(tp) and U.key(tp) or 0
            local tm = k ~= 0 and t.byPs[k] or nil
            if tm and tm ~= m then holdEntry(e, ab, m, tm, r) end
        end
    end
end

--- FAST tick (main.lua, race phases): layer 1, and the hooks of layers 2-3 armed on the first OFF race
function M.fastTick()
    if not M.enabledNow() then return end
    M.arm()
    local r, t = race(), M.team()
    for _, m in ipairs(t.list) do
        for _, ab in ipairs(targetingOf(m, r)) do
            if U.ok(ab) then scanAbility(ab, m, t, r) end
        end
    end
end

---------------------------------------------------------------------------------------------------- layer 2: overlaps
local function swapTo(owner, helper, mode)
    if mode == "self" then return helper end
    return owner.car
end

-- a hook parameter's value: a RemoteUnrealParam (live) or a {get, set} table (tools/test_friendly.lua)
local function pv(p)
    if type(p) == "table" and type(p.get) == "function" then return p:get() end
    return U.unwrap(p)
end
M._pv = pv

local function setParam(p, v)
    if type(p) == "table" and type(p.set) == "function" then return pcall(p.set, p, v) end
    return pcall(function() p:set(v) end)
end

-- the helper's human owner and the overlapped teammate, when this overlap is a friendly one
local function friendlyOverlap(ctx, other)
    if not M.enabledNow() then return nil end
    local t = M.team()
    local helper = pv(ctx)
    if not U.ok(helper) then return nil end
    local own = nil
    pcall(function() own = helper.mOwningVehicle end)
    local om = U.ok(own) and t.byCar[U.key(own)] or nil
    if not om or om.car == nil then return nil end
    local oa = pv(other)
    local tm = U.ok(oa) and t.byCar[U.key(oa)] or nil
    if not tm or tm == om then return nil end
    return om, tm, helper
end

function M.onOverlapStart(ctx, _overlapped, otherP)
    local om, tm, helper = friendlyOverlap(ctx, otherP)
    if not om then return end
    local r = race()
    local mode = opt("CouchFriendlyFireOverlapSwap", "owner")
    local okS = setParam(otherP, swapTo(om, helper, mode))
    bump(r, "swaps", "ov" .. om.pnum .. ">" .. tm.pnum, "friendly fire OFF: %s's %s overlapped teammate %s: the overlap "
        .. "goes to %s %s (V-FF-02)", pname(om), U.className(helper), pname(tm), mode == "self" and "the helper" or
        "its own car", okS and "ok" or "FAILED")
end

function M.onComponentOverlapStart(ctx, overlappedComp, otherP, otherCompP)
    local om, tm, helper = friendlyOverlap(ctx, otherP)
    if not om then return end
    local r = race()
    local mode = opt("CouchFriendlyFireOverlapSwap", "owner")
    local okS = setParam(otherP, swapTo(om, helper, mode))
    local comp = nil
    if mode == "self" then
        comp = pv(overlappedComp)
    else
        pcall(function() comp = om.car.RootComponent end)
    end
    local okC = U.ok(comp) and setParam(otherCompP, comp)
    bump(r, "swaps", "ovc" .. om.pnum .. ">" .. tm.pnum, "friendly fire OFF: %s's %s (component overlap) reached "
        .. "teammate %s: actor -> %s %s, component %s (V-FF-02)", pname(om), U.className(helper), pname(tm),
        mode == "self" and "the helper" or "its own car", okS and "ok" or "FAILED", okC and "ok" or "kept")
end

-- AbilityShockwaveSource:Multi_AddVehicle(vehiclePawn, strength) pre
function M.onPush(ctx, vehP, strengthP)
    if not M.enabledNow() then return end
    local t = M.team()
    local om = M.ownerOf(ctx, t)
    if not om then return end
    local v = pv(vehP)
    local tm = U.ok(v) and t.byCar[U.key(v)] or nil
    if not tm or tm == om then return end
    local ok = setParam(strengthP, 0.0)
    bump(race(), "pushes", "push" .. om.pnum .. ">" .. tm.pnum, "friendly fire OFF: %s's shockwave pushed teammate %s: "
        .. "Strength -> 0 %s (V-FF-04)", pname(om), pname(tm), ok and "ok" or "FAILED")
end

---------------------------------------------------------------------------------------------------- leak detection
local function leak(r, om, tm, what)
    r.stats.leaks = r.stats.leaks + 1
    U.logEvery("friendly.leak" .. om.pnum .. ">" .. tm.pnum .. what, 3000, TAG, "WARN friendly fire OFF: %s's %s still "
        .. "reached teammate %s (%d leak(s) this race) (V-FF-03)", pname(om), what, pname(tm), r.stats.leaks)
end

local function teamIn(list, t, om, r, what)
    for _, v in ipairs(U.arrayToTable(list)) do
        local x = U.unwrap(v)
        local tm = U.ok(x) and (t.byCar[U.key(x)] or t.byPs[U.key(x)]) or nil
        if tm and tm ~= om then leak(r, om, tm, what) end
    end
end

function M.onLockFinished(ctx, targetP)
    if not M.enabledNow() then return end
    local t = M.team()
    local om = M.ownerOf(ctx, t)
    if not om then return end
    local x = pv(targetP)
    local tm = U.ok(x) and (t.byPs[U.key(x)] or t.byCar[U.key(x)]) or nil
    if tm and tm ~= om then leak(race(), om, tm, "bolt lock (" .. U.className(pv(ctx)) .. ")") end
end

function M.onDisrupted(ctx, disruptedP, deshieldedP)
    if not M.enabledNow() then return end
    local t = M.team()
    local om = M.ownerOf(ctx, t)
    if not om then return end
    local r = race()
    local a = nil
    pcall(function() a = pv(disruptedP) end)
    teamIn(a, t, om, r, "bolt (disrupted)")
    local b = nil
    pcall(function() b = pv(deshieldedP) end)
    teamIn(b, t, om, r, "bolt (shield broken)")
end

function M.onModularOverlap(ctx, otherP)
    if not M.enabledNow() then return end
    local t = M.team()
    local om = M.ownerOf(ctx, t)
    if not om then return end
    local x = pv(otherP)
    local tm = U.ok(x) and t.byCar[U.key(x)] or nil
    if tm and tm ~= om then leak(race(), om, tm, "attack overlap (" .. U.className(pv(ctx)) .. ")") end
end

---------------------------------------------------------------------------------------------------- arming / summary
local armed = false
function M.armed() return armed end
function M.arm()
    if armed then return end
    armed = true
    local H = M.HOOKS
    U.hook(H.ovStart, { pre = function(ctx, a, b) M.onOverlapStart(ctx, a, b) end }, TAG)
    U.hook(H.ovComp, { pre = function(ctx, a, b, c) M.onComponentOverlapStart(ctx, a, b, c) end }, TAG)
    U.hook(H.push, { pre = function(ctx, v, s) M.onPush(ctx, v, s) end }, TAG)
    U.hook(H.lockDone, { pre = function(ctx, p) M.onLockFinished(ctx, p) end }, TAG)
    U.hook(H.disrupted, { pre = function(ctx, a, b) M.onDisrupted(ctx, a, b) end }, TAG)
    U.hook(H.modular, { pre = function(ctx, v) M.onModularOverlap(ctx, v) end }, TAG)
    U.log(TAG, "friendly fire OFF: first race of the session - lock hold every FAST tick, overlap / push hooks armed "
        .. "(lock %s, overlap swap %s) (V-FF-00)", tostring(opt("CouchFriendlyFireLock", "hold")),
        tostring(opt("CouchFriendlyFireOverlapSwap", "owner")))
end

function M.summary(why)
    if R == nil or R.summarised then return end
    local s = R.stats
    R.summarised = true
    if s.held + s.dropped + s.swaps + s.pushes + s.leaks + s.skipped == 0 then return end
    U.log(TAG, "friendly fire OFF, race over (%s): %d lock reset(s) on a teammate, %d dropped, %d overlap(s) moved off a teammate, %d "
        .. "push(es) zeroed, %d untouched (unknown lock timer), %d leak(s) (V-FF-05)", tostring(why), s.held, s.dropped,
        s.swaps, s.pushes, s.skipped, s.leaks)
end

function M.init()
    St.on("leaving", TAG, function(why) U.try(TAG, M.summary, why) end)
    St.on("phase", TAG, function(new)
        if new == "POSTRACE" or new == "FRONTEND" then U.try(TAG, M.summary, new) end
    end)
    U.log(TAG, "init: CouchFriendlyFire=%s (couch campaign races; OPTIONS > COUCH CAMPAIGN)", M.rule())
end

return M
