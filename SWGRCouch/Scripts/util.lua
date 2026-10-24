-- SWGRCouch / util.lua  (G1 Core)
-- Logging, error isolation, validity helpers, value helpers, class/object cache (LoadAsset fallback),
-- world / GameInstance / local-player / subsystem / CSM helpers, console + cvars, hook registry with
-- pending-hook retry. Contract: ARCHITECTURE.md §4.0 and §4.2 `util`.
-- Threads: logging/try/value helpers are thread-agnostic. Everything that touches a UObject must run on
-- the game thread (callers go through sched.lua or a hook). LoadAsset is only attempted on the game thread.

local C   = require("consts")
local cfg = require("config")
local St  = require("state")
local UEHelpers = require("UEHelpers")

local U = {}

local fmt, tostr, sfind, ssub = string.format, tostring, string.find, string.sub

---------------------------------------------------------------------------------------------------- logging
local function render(f, ...)
    if select("#", ...) == 0 then return tostr(f) end
    local ok, s = pcall(fmt, tostr(f), ...)
    if ok then return s end
    -- bad format string or argument: never throw from a logger
    local parts = { tostr(f) }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostr((select(i, ...))) end
    return table.concat(parts, " | ")
end

local function emitLine(tag, level, msg)
    -- print() does not add a newline in UE4SS [API§12]
    print("[" .. C.MOD .. "][" .. tostr(tag or "?") .. "] " .. level .. msg .. "\n")
    -- couch-fix75 (#8): WARN / ERROR lines also go to the session trail (trail.lua sets U.trailHook; never throws)
    if level ~= "" and level ~= "dbg " and U.trailHook ~= nil then pcall(U.trailHook, tag, level, msg) end
end

function U.log(tag, f, ...)  emitLine(tag, "", render(f, ...)) end
function U.warn(tag, f, ...) emitLine(tag, "WARN ", render(f, ...)) end
function U.err(tag, f, ...)  emitLine(tag, "ERROR ", render(f, ...)) end
function U.dbg(tag, f, ...)
    if cfg.Debug then emitLine(tag, "dbg ", render(f, ...)) end
end

local onceKeys = {}
--- Log once per key for the whole session.
function U.logOnce(key, tag, f, ...)
    if onceKeys[key] then return end
    onceKeys[key] = true
    U.log(tag, f, ...)
end

local everyKeys = {}
--- Log at most once per `ms` per key.
function U.logEvery(key, ms, tag, f, ...)
    local now = St.nowMs()
    local last = everyKeys[key]
    if last and now - last < (ms or 0) then return end
    everyKeys[key] = now
    U.log(tag, f, ...)
end

---------------------------------------------------------------------------------------------------- errors
--- xpcall with traceback. Returns true, results... or false (error logged with traceback).
-- 0.12.0 debug breadcrumbs: a native crash's minidump holds no Lua stack, so while _G.SWGRCouch_traceLeft > 0 (set
-- from test.cmd only) U.try / U.tryEvery log their tag before running and count it down. Off: one rawget per call.
local function trace(kind, what)
    local left = rawget(_G, "SWGRCouch_traceLeft")
    if type(left) == "number" and left > 0 then
        _G.SWGRCouch_traceLeft = left - 1
        U.log("trace", "%s %s", kind, tostr(what))
    end
end

U.trace = trace

-- couch-racegc: no table.pack per call (U.try / U.tryEvery wrap every module tick: ~55 calls per 33 ms FAST run, each
-- packing its results was ~100 bytes of garbage per call); the results stay on the stack through a vararg tail.
local function tryDone(tag, ok, ...)
    if ok then return ok, ... end
    U.err(tag, "%s", tostr((...)))
    return false
end
function U.try(tag, fn, ...)
    trace("try", tag)
    if type(fn) ~= "function" then
        U.err(tag, "U.try: not a function (%s)", type(fn))
        return false
    end
    return tryDone(tag, xpcall(fn, debug.traceback, ...))
end

--- pcall(o:name(...)) without a closure (couch-racegc: `pcall(callMethod, o, "F")` allocates a closure and an
--- upvalue per call, ~80 bytes; a race tick made thousands). The index and the call both run inside the pcall.
local function callMethod(o, name, ...) return o[name](o, ...) end
U.callMethod = callMethod
function U.pcallM(o, name, ...) return pcall(callMethod, o, name, ...) end
-- couch-fix67 (AUTO-152 generalised, see "class pins" below): U.ok and U.getField keep the class of every Blueprint
-- object they see loaded for the session. Set once the pin code below is defined (nil while util.lua loads).
local keepObj, keepAny = nil, nil
--- pcall(o[k]) without a closure: ok, value
local function getField(o, k)
    if keepAny ~= nil and type(k) == "string" then keepAny(o) end   -- a by-name member read (never an array index)
    return o[k]
end
U.getField = getField
function U.pcallGet(o, k) return pcall(getField, o, k) end

--- U.try for code that runs on every FAST/MAIN tick: the first error of `key` is logged with its traceback, later
--- ones at most one line per `ms` (default cfg.LoopErrorLogEveryMs) with the count suppressed in between. A
--- persistent fault in a 33 ms loop must not print ~30 tracebacks per second (UE4SS.log + the GUI console stall
--- the game thread). Same results as U.try.
local tryEveryState = {}
function U.tryEvery(key, ms, tag, fn, ...)
    trace("every", key)
    if type(fn) ~= "function" then
        U.logEvery("tryEvery!" .. tostr(key), 60000, tag, "ERROR U.tryEvery(%s): not a function (%s)", tostr(key), type(fn))
        return false
    end
    return U.tryEveryDone(key, ms, tag, xpcall(fn, debug.traceback, ...))
end
function U.tryEveryDone(key, ms, tag, ok, ...)
    if ok then return ok, ... end
    local r = { ok, ... }
    local now = St.nowMs()
    local st = tryEveryState[key]
    if not st then st = { lastMs = nil, suppressed = 0, total = 0 }; tryEveryState[key] = st end
    st.total = st.total + 1
    local every = tonumber(ms) or tonumber(cfg.LoopErrorLogEveryMs) or 5000
    if st.lastMs == nil or now - st.lastMs >= every then
        if st.suppressed > 0 then
            U.err(tag, "[%s] error #%d (%d suppressed since the last report): %s", tostr(key), st.total, st.suppressed,
                tostr(r[2]))
        else
            U.err(tag, "[%s] %s", tostr(key), tostr(r[2]))
        end
        st.lastMs, st.suppressed = now, 0
    else
        st.suppressed = st.suppressed + 1
    end
    return false
end

--- Lazy access to another module (avoids half-initialised tables from circular requires).
function U.mod(name)
    return require(name)
end

---------------------------------------------------------------------------------------------------- validity
--- true when o is a live UObject wrapper (UE4SS IsValid: non-null, in the object map, reachable [API§7]).
local function isValidOf(o) return o:IsValid() end
function U.ok(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, v = pcall(isValidOf, o)
    if ok and v == true then
        if keepObj ~= nil then keepObj(o) end      -- couch-fix67: its Blueprint class kept loaded (class pins below)
        return true
    end
    return false
end

local kslIsValidBroken = false
local KSL_ISVALID = nil   -- cached UFunction /Script/Engine.KismetSystemLibrary:IsValid

-- NOTE: `obj:IsValid()` ALWAYS resolves to the UE4SS built-in wrapper method (LuaUObject.hpp:761):
-- LuaMadeSimple's __index (LuaMadeSimple.cpp:541-560) returns built-in member functions before it
-- looks up reflected properties/UFunctions, so no reflected function named IsValid is reachable
-- through `:` syntax. `ksl:IsValid(o)` would test the KSL CDO and silently ignore `o`.
-- The engine function must therefore be called explicitly through its UFunction object.

--- Raw call of UKismetSystemLibrary::IsValid(Object) -> Bool. Returns ok, value (value may be non-boolean on failure).
--- Not cached on failure, so it can be retried later (e.g. before the engine module is ready).
function U.kslIsValidRaw(o)
    local ksl = U.KSL()
    if not U.ok(ksl) then return false, "KismetSystemLibrary CDO not found" end
    if not U.ok(KSL_ISVALID) then
        local okF, f = pcall(StaticFindObject, "/Script/Engine.KismetSystemLibrary:IsValid")
        if not okF or not U.ok(f) then return false, "UFunction KismetSystemLibrary:IsValid not found" end
        KSL_ISVALID = f
    end
    -- KSL::IsValid(Object Object) -> Bool   [reflect-func-all: FunctionFlags=0x14022401, outer = UKismetSystemLibrary]
    -- Built-in CallFunction (LuaUObject.hpp:647 -> call_ufunction_from_lua): self = calling context,
    -- first arg = the UFunction, then exactly the declared params (1) [API§9].
    -- VERIFY(V-CORE-05): returns a Lua boolean and does not throw.
    return pcall(callMethod, ksl, "CallFunction", KSL_ISVALID, o)
end

--- U.ok plus, when cfg.UseKslIsValid, KismetSystemLibrary::IsValid (catches Garbage-marked actors).
function U.alive(o)
    if not U.ok(o) then return false end
    if not cfg.UseKslIsValid or kslIsValidBroken then return true end
    if not U.ok(U.KSL()) then return true end
    -- VERIFY(V-CORE-05): fallback cfg.UseKslIsValid = false (U.alive == U.ok)
    local ok, v = U.kslIsValidRaw(o)
    if not ok or type(v) ~= "boolean" then
        kslIsValidBroken = true
        U.warn("util", "KismetSystemLibrary::IsValid unusable (%s); U.alive = U.ok from now on", tostr(v))
        return true
    end
    return v
end

--- Address of a UObject as an integer table key; 0 when invalid.
function U.key(o)
    if not U.ok(o) then return 0 end
    local ok, a = pcall(callMethod, o, "GetAddress")
    if ok and type(a) == "number" then return a end
    return 0
end

-- couch-fix59 (AUTO-145e, live round 4: END GRAND PRIX / START with un-joined pads took the second A only within
-- ~1-2 s; a second A 3 s later re-armed the prompt and looked like a dead button): every press-twice confirmation of
-- the mod uses this one window (cfg.ConfirmWindowMs, default 5 s), measured on St.nowMs (the real clock).
function U.confirmMs()
    local v = tonumber(cfg.ConfirmWindowMs)
    if not v or v < 1000 then v = 5000 end
    return v
end

--- Both valid and the same object (UE4SS `==` compares pointers [API§7]).
function U.same(a, b)
    return U.ok(a) and U.ok(b) and a == b
end

-- NULL-UNSAFE BUILT-INS. A UE4SS wrapper whose UObject pointer is NULL is a truthy userdata: a null object property
-- (pc.Pawn with no car), a UFunction returning no object, a FindFirstOf / StaticFindObject miss. Its property reads
-- (another null wrapper) and UFunction calls (a Lua error) are safe, but GetClass ([obj+0x10], UE4SS.dll+0x2ace40:
-- the "UE4SS.dll+0x2ace67 reading null+0x10" crashes of 2026-10-14), GetFName (+0x18), GetOuter (+0x20),
-- IsClass/IsAnyClass, AActor:GetLevel and the UStruct/UClass walkers dereference it with no null check: a native
-- access violation that pcall does NOT catch. Use these helpers (tools/lint_uobject_guards.lua enforces it).

-- FINDING #31 (live 2026-10-17 19:05:35 UTC, crash_2026_10_17_19_05_35.9674787.dmp): AV in UE4SS.dll+0x2ace27 reading
-- 0x18 = the Lua UObject:GetFName lambda (UE4SS.dll+0x2ace00, registered as "GetFName" next to GetClass +0x2ace40) on a
-- NULL wrapper. Every direct :GetFName() of the mod was already behind U.ok on its receiver; the one unguarded receiver
-- was the CLASS in o:GetClass():GetFName() (the lint exempted it: "the class of a live object is never null"). U.ok only
-- proves the wrapper's pointer is in UE4SS's live-object set: a widget whose memory is being torn down / recycled can
-- pass it with a NULL ClassPrivate, and GetClass then hands out a NULL wrapper. The class is now U.ok'ed too, here and
-- in U.clsStr (every former GetClass():GetFName() chain of the mod).
--- Class short name of o as a string; raises a Lua error (never a native AV) when o or its class is nil / null / dead.
function U.clsStr(o)
    if not U.ok(o) then error("invalid object", 2) end
    local c = o:GetClass()
    if not U.ok(c) then error("object without a valid class", 2) end
    local s = c:GetFName():ToString()
    if type(s) ~= "string" then error("class name unreadable", 2) end
    return s
end

-- FINDING #42 (live 2026-10-17 22:07:44 UTC, crash_2026_10_17_22_07_44.2801614.dmp): ACCESS VIOLATION in
-- SWGR-Win64-Shipping.exe+0x9338e7 (FWidgetAnimationState init under execPlayAnimation +0x931c12, called from UE4SS's
-- UFunction call +0x49f7a5 inside a Lua callback), InAnimation = 0x814600010000000f. couchflow's COLLECT played
-- w.Anim_Out on WBP_PostRace_Rewards_CreditsBreakdown_Presentation_C, which has no such animation (decoded: Anim_In,
-- Anim_ContinueBtn). A missing member is NOT nil in UE4SS: it is a "TrivialObject" placeholder (special_invalid_ptr,
-- IsValid false), and push_objectproperty takes any userdata as an object parameter and writes its bytes as the
-- UObject*. pcall cannot catch the AV. Every widget animation of the mod goes through these two helpers.
--- The widget animation `name` of w when it really exists (a live UWidgetAnimation), else nil.
function U.anim(w, name)
    if not U.ok(w) or type(name) ~= "string" then return nil end
    local a = nil
    pcall(function() a = w[name] end)
    if U.ok(a) then return a end                 -- U.ok: the TrivialObject placeholder's IsValid is false
    return nil
end
--- w:PlayAnimation(w[name], start, 1 loop, mode, 1.0, false) only when that animation exists. -> true when played
function U.playAnim(w, name, mode, start)
    local a = U.anim(w, name)
    if not a then return false end
    local ok = pcall(function() w:PlayAnimation(a, start or 0, 1, mode or 0, 1, false) end)
    return ok
end

--- Class short name ("WBP_Foo_C") of a live object; "" when o (or its class) is nil / null / dead.
function U.className(o)
    if not U.ok(o) then return "" end
    local ok, s = pcall(U.clsStr, o)
    return (ok and type(s) == "string") and s or ""
end

--- Object short name of a live object; "" when o is nil / null / dead.
function U.objName(o)
    if not U.ok(o) then return "" end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return (ok and type(s) == "string") and s or ""
end

--- Class object of a live object; an invalid object when o is nil / null / dead (U.pathOf / U.ok handle it).
function U.classOf(o)
    if not U.ok(o) then return CreateInvalidObject() end
    local ok, c = pcall(callMethod, o, "GetClass")
    if ok and c ~= nil then return c end
    return CreateInvalidObject()
end

--- Outer of a live object; an invalid object when o is nil / null / dead (chains stop there: U.ok is false).
function U.outerOf(o)
    if not U.ok(o) then return CreateInvalidObject() end
    local ok, x = pcall(callMethod, o, "GetOuter")
    if ok and x ~= nil then return x end
    return CreateInvalidObject()
end

---------------------------------------------------------------------------------------------------- values
--- Unwrap a RemoteUnrealParam / LocalUnrealParam (hook params, TArray-return elements); other values pass.
local function unwrapParam(v)
    if type(v) ~= "userdata" then return v end
    local ok, t = pcall(callMethod, v, "type")
    if ok and (t == "RemoteUnrealParam" or t == "LocalUnrealParam") then
        local ok2, inner = pcall(callMethod, v, "get")
        if ok2 then return inner end
    end
    return v
end
U.unwrap = unwrapParam

--- FString / FText / FName -> Lua string; Lua strings pass; params are unwrapped; else tostring.
function U.str(v)
    if v == nil then return "" end
    local tv = type(v)
    if tv == "string" then return v end
    if tv ~= "userdata" then return tostr(v) end
    v = unwrapParam(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(callMethod, v, "ToString")
    if ok and type(s) == "string" then return s end
    return tostr(v)
end

local fnameCache = {}
--- FName for a Lua string, cached per string (FName("x") = FNAME_Add [API§8]).
function U.fname(s)
    s = tostr(s)
    local n = fnameCache[s]
    if n == nil then
        n = FName(s)
        fnameCache[s] = n
    end
    return n
end

--- New FText each call (FText params accept only FText userdata [API§8]).
function U.ftext(s)
    return FText(tostr(s))
end

--- TArray userdata (numeric loop to GetArrayNum, never past the end [API§8]) or the Lua table a UFunction
--- returns for an array return value (elements are RemoteUnrealParams there: unwrapped with :get()).
--- VERIFY(V-CORE-08): GetInputSourceOverrides()/GetAllChildren() returns come back as tables of params.
function U.arrayToTable(arr)
    local out = {}
    if arr == nil then return out end
    if type(arr) == "table" then
        for i = 1, #arr do out[#out + 1] = unwrapParam(arr[i]) end
        return out
    end
    if type(arr) ~= "userdata" then return out end
    local ok, n = pcall(callMethod, arr, "GetArrayNum")
    if not ok or type(n) ~= "number" then return out end
    for i = 1, n do
        local okE, v = pcall(getField, arr, i)
        if okE then out[#out + 1] = unwrapParam(v) end
    end
    return out
end

--- Element count of a TArray userdata or a Lua table; 0 otherwise.
function U.arrayCount(arr)
    if type(arr) == "table" then return #arr end
    if type(arr) ~= "userdata" then return 0 end
    local ok, n = pcall(callMethod, arr, "GetArrayNum")
    if ok and type(n) == "number" then return n end
    return 0
end

--- Object path without the class prefix: GetFullName() = "<Class> <path>" [API§7]. "" when invalid.
function U.pathOf(obj)
    if not U.ok(obj) then return "" end
    local ok, full = pcall(callMethod, obj, "GetFullName")
    if not ok or type(full) ~= "string" then return "" end
    local sp = sfind(full, " ", 1, true)
    if sp then return ssub(full, sp + 1) end
    return full
end

--- "/Game/X/WBP_A.WBP_A_C" -> "/Game/X/WBP_A.WBP_A" (LoadAsset wants the asset path [API§10]).
function U.assetPathFromClassPath(p)
    p = tostr(p)
    if ssub(p, -2) == "_C" then return ssub(p, 1, -3) end
    return p
end

---------------------------------------------------------------------------------------------------- classes / objects
local classCache, objCache, cdoCache = {}, {}, {}
-- A cached UObject address can be REUSED: an unloaded BP class / asset is garbage-collected and another object lands
-- at the same address, still "valid" for U.ok (live 2026-10-18, tester #3: U.class(rewards layout) returned
-- WBP_Hud_EventLapCounter_C after a few races -> the guest's reward copy was created from the HUD class, "attempt to
-- call a TrivialObject value (method 'SetVM')", list fallback twice). A cache hit is re-checked by NAME (the path's last
-- segment) once per world and at most every CACHE_NAME_MS, so hot per-tick callers pay one GetFName rarely.
local CACHE_NAME_MS = 2000
local cacheChecked = {}            -- [path] = { gen = world, at = ms }
local function stillNamed(path, o)
    if not U.ok(o) then return false end
    local c = cacheChecked[path]
    local now = St.nowMs()
    if c and c.gen == St.worldGen and now - c.at < CACHE_NAME_MS then return true end
    local want = string.match(path, "[.:]([^.:/]+)$")
    if want then
        local ok, nm = pcall(function() return o:GetFName():ToString() end)
        if ok and type(nm) == "string" and nm ~= want then
            cacheChecked[path] = nil
            U.logOnce("stale:" .. path, "util", "cache: %s now points at %s (address reused after a GC): looked up again",
                path, nm)
            return false
        end
    end
    cacheChecked[path] = { gen = St.worldGen, at = now }
    return true
end
local loadTried = {}            -- path -> St.nowMs() of the last LoadAsset attempt (throttle)
local LOAD_RETRY_MS = 5000

local function inGameThread()
    local ok, v = pcall(function() return IsInGameThread() end)
    return ok and v == true
end

local function findObject(path)
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.ok(o) then return o end
    return nil
end

-- StaticFindObject costs ~2.5 ms in this build EVEN WHEN THE OBJECT EXISTS (live-measured 2026-10-13; UE4SS
-- with the custom AOBs on this UE5.7 exe). One raw find inside a FAST/MAIN poll is a dropped frame, and the
-- CSM polls alone did 4+ of them per 33 ms (the 0.13 split-race stutter). Per-tick callers go through this
-- cache: a hit is re-validated with U.ok; a miss is retried after missTtl ms (default FIND_MISS_MS), or at
-- once when the world or the phase changed (map loads and phase flips are what make missing objects appear).
local findCache, findMissAt = {}, {}
local findMissWorld, findMissPhase = nil, nil
local FIND_MISS_MS = 10000
local function findObjectCached(path, missTtl)
    local o = findCache[path]
    if o ~= nil and U.ok(o) and stillNamed(path, o) then return o end
    findCache[path] = nil
    if findMissWorld ~= St.worldGen or findMissPhase ~= St.phase then
        findMissWorld, findMissPhase, findMissAt = St.worldGen, St.phase, {}
    end
    local at = findMissAt[path]
    if at and St.nowMs() - at < (missTtl or FIND_MISS_MS) then return nil end
    o = findObject(path)
    if o then
        findCache[path] = o; findMissAt[path] = nil
    else
        findMissAt[path] = St.nowMs()
    end
    return o
end

---------------------------------------------------------------------------------------------------- hot UFunction calls
-- couch-racegc: `obj:Fn(...)` makes UE4SS build a NEW UFunction wrapper (a finalizable userdata, ~265 bytes) at every
-- method lookup; the race ticks made thousands a second (IsInputKeyDown alone: ~8 per FAST tick in pause.lua).
--- pcall(o:<name>(...)) without a new UFunction wrapper per call: ok, results...
-- LIVE 2026-10-16 (UE4SS 3f4037d2, couch-racegc test launch): the built-in CallFunction REFUSES a UFunction found by
-- StaticFindObject ("[UFunction::call_ufunction_from_lua] Tried calling function without both UFunction and calling
-- context": the found object is a plain UObject wrapper, not a LuaType::UFunction - the same failure that makes
-- KismetSystemLibrary::IsValid "unusable" every session). Instead the wrapper UE4SS returns for `o.<name>` is kept,
-- per object WRAPPER (weak keys: the entry goes with the wrapper), and called again: a UFunction wrapper carries the
-- object it was looked up on as its calling context (call_ufunction_from_lua takes func + base from it and discards
-- the self argument), so `f(o, ...)` IS `o:<name>(...)`. `path` is kept for the callers (documentation only).
local memberCache = setmetatable({}, { __mode = "k" })
local memberHits = { hit = 0, miss = 0 }
function U.pcallFn(o, path, name, ...)
    local t = memberCache[o]
    local f = t and t[name]
    if f == nil then
        if type(o) ~= "userdata" then return pcall(callMethod, o, name, ...) end
        local ok, m = pcall(getField, o, name)
        if not ok or type(m) ~= "userdata" then return pcall(callMethod, o, name, ...) end
        if not t then t = {}; memberCache[o] = t end
        t[name], f = m, m
        memberHits.miss = memberHits.miss + 1
    else
        memberHits.hit = memberHits.hit + 1
    end
    return pcall(f, o, ...)
end
function U.memberCacheStats() return memberHits.hit, memberHits.miss end

local KEYDOWN_FN = "/Script/Engine.PlayerController:IsInputKeyDown"
--- PlayerController:IsInputKeyDown(FKey) -> true / false (false on any error); key = {KeyName = FName}
function U.keyDown(pc, key)
    local ok, v = U.pcallFn(pc, KEYDOWN_FN, "IsInputKeyDown", key)
    return ok and v == true
end

--- Cached find-only lookup (never LoadAsset) for per-tick polls; nil while the object is not in memory.
--- missTtl (ms, default 10000) = how long a miss is trusted before the next real StaticFindObject.
function U.findLoaded(path, missTtl)
    if type(path) ~= "string" or path == "" then return nil end
    return findObjectCached(path, missTtl)
end

--- couch-fix76 (AUTO-171): the game's UI mapping context IMC_UI. Live 2026-10-22 / 10-24 (hotfix CL386500): its
--- 1.0.x path never resolved ("IMC_UI not in memory" / "owner IMC_UI not loaded" in every session on that build), so
--- no guest got UI input on his own pause menu (his D-pad = his vehicle's ability slots: the row highlight went, A only
--- resumed through menubridge), the shared screens' owner boost and P1's vehicle-over-UI guard were dead too.
--- Order: the paths (cached finds, U.IMC_UI_PATHS); at most every 30 s one FindAllOf("InputMappingContext") by name
--- (U.IMC_UI_NAMES). cfg.ImcUiFallback = false: the paths only. (Reading UEnhancedPlayerInput.AppliedInputContexts was
--- tried live: UE4SS returned nothing, and the next hot reload crashed in UE4SS's Lua VM - never read it.)
--- -> imc, how ("path" | "scan") | nil, why   (CL386500: IMC_UI_PadAndDefaultKB, see U.IMC_UI_PATHS)
--- LIVE 2026-10-24 14:28 (fix76, CL386500): the hotfix split IMC_UI into IMC_UI_PadAndDefaultKB (pads + default keys)
--- and IMC_UI_KB_QWERTY (keyboard layout), both at 500 on P1 (HasMappingContext); no "IMC_UI" exists any more and
--- AppliedInputContexts reads empty through UE4SS. The pad context is the guests' UI context now: by path first.
U.IMC_UI_PATH = "/Game/Griffin/Config/Input/UI/IMC_UI.IMC_UI"
U.IMC_UI_PATHS = { "/Game/Griffin/Config/Input/UI/IMC_UI_PadAndDefaultKB.IMC_UI_PadAndDefaultKB", U.IMC_UI_PATH }
U.IMC_UI_NAMES = { IMC_UI_PadAndDefaultKB = true, IMC_UI = true }
local imcUi = { obj = nil, how = nil, scanAt = -1e12, logged = {} }
local function imcUiNamed(o)
    return o ~= nil and U.ok(o) and U.IMC_UI_NAMES[U.objName(o)] == true
end
local function imcUiFound(o, how)
    imcUi.obj, imcUi.how = o, how
    if not imcUi.logged[how] then
        imcUi.logged[how] = true
        local p = ""
        pcall(function() p = U.pathOf(o) end)
        U.log("util", "IMC_UI found by %s: %s (V-PAU-10, AUTO-171)", how, tostring(p))
    end
    return o, how
end
function U.imcUi()
    if imcUiNamed(imcUi.obj) then return imcUi.obj, imcUi.how end
    imcUi.obj, imcUi.how = nil, nil
    for _, p in ipairs(U.IMC_UI_PATHS) do
        local o = findObjectCached(p, 1000)
        if o then return imcUiFound(o, "path") end
    end
    local okC, C = pcall(require, "config")
    if okC and type(C) == "table" and C.ImcUiFallback == false then return nil, "not at its path (fallback off)" end
    local now = St.nowMs()
    if now - imcUi.scanAt < 30000 then return nil, "not at its paths (scan again in < 30 s)" end
    imcUi.scanAt = now
    local all = nil
    pcall(function() all = FindAllOf("InputMappingContext") end)
    for _, imc in ipairs(type(all) == "table" and all or {}) do
        if imcUiNamed(imc) then return imcUiFound(imc, "scan") end
    end
    return nil, "not in memory (paths, scan)"
end
function U._imcUiReset() imcUi.obj, imcUi.how, imcUi.scanAt, imcUi.logged = nil, nil, -1e12, {} end

--- LoadAsset(assetPath) on the game thread, at most once per LOAD_RETRY_MS per path. 3 returns [API§10].
local function tryLoad(assetPath)
    if not inGameThread() then return false end
    local now = St.nowMs()
    local last = loadTried[assetPath]
    if last and now - last < LOAD_RETRY_MS then return false end
    loadTried[assetPath] = now
    local ok, obj, found, loaded = pcall(LoadAsset, assetPath)
    if not ok then
        U.warn("util", "LoadAsset(%s) failed: %s", assetPath, tostr(obj))
        return false
    end
    -- logged once per path even with Debug off: the boot log answers V-CORE-12
    U.logOnce("load:" .. assetPath, "util", "LoadAsset(%s): found=%s loaded=%s",
        assetPath, tostr(found), tostr(loaded))
    -- the loaded object too: StaticFindObject matches the package path CASE-SENSITIVELY, and the asset registry (the
    -- pak listing) does not always spell it like the package (live 2026-10-18, tester #3: ".../Corgi/LOOP_B/..." loads
    -- ShakedownEventDef ".../Corgi/Loop_B/...", and StaticFindObject("...LOOP_B...") stays nil after the load)
    local lo = nil
    if found == true and obj ~= nil and U.ok(obj) then lo = obj end
    return found == true, lo
end

--- Resolve a C.CLASS / C.BP key or a full object path to a path string (nil if unknown).
local function classPathOf(keyOrPath)
    if type(keyOrPath) ~= "string" then return nil end
    if C.CLASS[keyOrPath] then return C.CLASS[keyOrPath] end
    if C.BP[keyOrPath] then return C.BP[keyOrPath] end
    if ssub(keyOrPath, 1, 1) == "/" then return keyOrPath end
    return nil
end

--- UClass for a key or path: cache -> StaticFindObject -> (/Game/..._C) LoadAsset(path without _C) -> find.
--- Returns an invalid object (CreateInvalidObject) when unresolved.
function U.class(keyOrPath)
    local path = classPathOf(keyOrPath)
    if not path then
        U.logOnce("class?" .. tostr(keyOrPath), "util", "U.class: unknown key %s", tostr(keyOrPath))
        return CreateInvalidObject()
    end
    local c = classCache[path]
    if c and U.ok(c) and stillNamed(path, c) then return c end
    classCache[path] = nil
    c = findObject(path)
    if not c and ssub(path, 1, 6) == "/Game/" and ssub(path, -2) == "_C" then
        -- a BP asset path usually reports "found but not loaded, could be a package" while the package
        -- (and its _C class) does get loaded [API§10], so look again whatever tryLoad returned
        -- VERIFY(V-CORE-12): LoadAsset("<Pkg>.<Pkg>") loads the BP package so StaticFindObject("<Pkg>.<Pkg>_C")
        -- resolves (UE4SS LuaMod.cpp:3355-3372: GetAssetByObjectPath + UAssetRegistryHelpers::GetAsset; a path
        -- missing from the asset registry loads nothing and returns found=false).
        local foundPkg = tryLoad(U.assetPathFromClassPath(path))
        c = findObject(path)
        if not c and not foundPkg then
            -- fallback: registry may index the generated class instead of the (cooked-out) Blueprint asset
            tryLoad(path)
            c = findObject(path)
        end
        if not c then
            U.logOnce("classload?" .. path, "util", "U.class: %s still unresolved after LoadAsset (V-CORE-12)", path)
        end
    end
    if c then
        classCache[path] = c
        return c
    end
    return CreateInvalidObject()
end

--- Non-class asset/object (CSM assets, data assets) by C.ASSET key or object path; LoadAsset fallback.
function U.obj(keyOrPath)
    local path = (type(keyOrPath) == "string" and C.ASSET[keyOrPath]) or keyOrPath
    if type(path) ~= "string" or path == "" then return CreateInvalidObject() end
    local o = objCache[path]
    if o and U.ok(o) and stillNamed(path, o) then return o end
    objCache[path] = nil
    o = findObject(path)
    if not o then
        local found, lo = tryLoad(path)
        if found then o = findObject(path) or lo end
    end
    if o then
        objCache[path] = o
        return o
    end
    return CreateInvalidObject()
end

--- Class default object from C.CDO (key) or a full "Default__" path.
function U.cdo(key)
    local path = C.CDO[key] or key
    local o = cdoCache[path]
    if o and U.ok(o) then return o end
    o = findObject(path)
    cdoCache[path] = o
    return o or CreateInvalidObject()
end

function U.GS()  return U.cdo("GameplayStatics") end
function U.KSL() return U.cdo("KismetSystemLibrary") end
function U.WBL() return U.cdo("WidgetBlueprintLibrary") end
function U.SBL() return U.cdo("SubsystemBlueprintLibrary") end
function U.GMS() return U.cdo("GameMapsSettings") end

--- IsA by C.CLASS/C.BP key or path (cached UClass; IsA accepts a UClass [API§7]).
function U.isA(o, keyOrPath)
    if not U.ok(o) then return false end
    local cls = U.class(keyOrPath)
    if not U.ok(cls) then return false end
    local ok, v = pcall(callMethod, o, "IsA", cls)
    return ok and v == true
end

function U.isVehicle(pawn)        return U.isA(pawn, "VehiclePawn") end

-- couch-racegc: a PC's car (pc.Pawn when it is a VehiclePawn, else nil), read once per loop run (St.loopSeq) and PC:
-- debugai, viewguard (twice), inputfix each read pc.Pawn every FAST tick (a new wrapper per read). Outside a loop run
-- (hooks, one-shots) it is read fresh. A cached car is U.ok-checked at every hit.
local carRun = { seq = nil, byPc = {} }
function U.carOf(pc)
    if not U.ok(pc) then return nil end
    local seq = St.loopSeq
    local k = U.key(pc)
    if seq ~= nil and carRun.seq == seq then
        local c = carRun.byPc[k]
        if c == false then return nil end
        if c ~= nil and U.ok(c) then return c end
    elseif seq ~= nil then
        carRun.seq, carRun.byPc = seq, {}
    end
    local ok, p = pcall(getField, pc, "Pawn")
    local car = (ok and U.ok(p) and U.isVehicle(p)) and p or nil
    if seq ~= nil then carRun.byPc[k] = car or false end
    return car
end
function U.isPlayerController(o)  return U.isA(o, "PlayerController") end

---------------------------------------------------------------------------------------------------- world
local giCache = nil
local giLastFindMs = -1e12
local worldFallbackMs = -1e12
local GI_FIND_EVERY_MS, WORLD_FALLBACK_EVERY_MS = 1000, 2000   -- §0 rule 6

--- GameInstance: FindFirstOf("GameInstance") (includes subclasses [API§6]) once, re-validated;
--- re-searched at most once per second while missing.  VERIFY(V-CORE-04): class BP_GfnGameInstance_C.
function U.gi()
    if giCache and U.ok(giCache) then return giCache end
    giCache = nil
    local now = St.nowMs()
    if now - giLastFindMs < GI_FIND_EVERY_MS then return CreateInvalidObject() end
    giLastFindMs = now
    local ok, gi = pcall(FindFirstOf, "GameInstance")
    if ok and U.ok(gi) then
        giCache = gi
        return gi
    end
    return CreateInvalidObject()
end

-- couch-fix63 (AUTO-152 crash_2026_10_20_11_06_05 + FINDING #44 crash_2026_10_17_23_02_01, both AV at UE4SS.dll+0x406911):
-- UE4SS GR Edition's UStruct::FindProperty (+0x400330) keeps a global cache (UStruct*, FName) -> FProperty* (+0x1344770;
-- written only at +0x40053a, never invalidated: no other code touches it). A Blueprint class the GC unloads (the race
-- HUD and ignition screen classes are hard references of RaceFlow CSM assets, which the GC unloads and reloads: the
-- "CSM_RF_Spectating now points at CSM_RF_Racing" cache line) leaves entries pointing at its FREED FProperties; a class
-- loaded later at the same address (UClass objects are all one size: the binned allocator hands the freed slot out
-- again) gets them back on the first by-name read of that member. While the freed memory is intact the read works
-- (same layout); once it was reused, handle_unreal_property_value reads the FFieldClass of garbage: the AV, under a
-- U.ok-valid object (U.ok cannot see it). The mod's side of the fix: the Blueprint classes whose members it reads
-- by name in a race are kept loaded for the session (GameInstance.ReferencedObjects, a UPROPERTY TArray<UObject*> of
-- the GameInstance: "objects kept alive by this game instance"), so their addresses are never handed to another
-- class and their cached FProperties stay theirs. A class keeps its WidgetTree archetype, so the nested widget
-- classes of a pinned HUD stay loaded with it. Native classes (/Script/) never unload: never pinned.
-- couch-fix67 (AUTO-152 generalised): fix63 pinned the race HUD and ignition classes by hand; every other Blueprint class
-- whose members the mod reads by name was safe only while the GC happened to keep it. Now the class of EVERY object the
-- mod validates (U.ok) or reads a member of (U.getField) is kept loaded the first time it is seen, when it is a generated
-- class that can unload (a "..._C" class outside /Script/: BlueprintGeneratedClass, WidgetBlueprintGeneratedClass, Anim
-- BPs...). Cost: per object ADDRESS once per world (objSeen, reset at each new world), one GetClass wrapper + one
-- GetFullName per class ADDRESS for the session (clsNever / pinnedK: a native class never unloads and a pinned one never
-- does either, so neither address is ever handed to another class); every later U.ok / getField of a known object is
-- one GetAddress (a built-in: no wrapper) + a table read. Never pinned: native classes, level script classes (keeping one
-- would keep its whole map), subobject classes (a ':' in the path). Bounded: cfg.ClassPinCap (default 1500; 400 until
-- couch-fix75: live sessions reached ~300 within an hour and every class past the cap is unprotected again) classes, one
-- WARN when reached; cfg.ClassPinAuto = false keeps only the named pins of fix63. Per world: one summary line
-- ("N Blueprint classes kept loaded"), and a sweep of the classes the mod looked up (U.class / U.findLoaded caches) that
-- are loaded now - pinned before the new world's first member read. The hooked Blueprint functions' classes too.
local pinnedW = setmetatable({}, { __mode = "k" })   -- wrapper -> true (no GetAddress per call on a cached wrapper)
local pinnedK = {}                                   -- class address -> path (kept for the session)
local pinnedObj = {}                                 -- couch-fix75: class address -> its wrapper (re-pin after a loss)
local pinScanned, pinBroken = false, nil
local pinCount, pinCapped = 0, false
local pinLastIdx = 0                                 -- couch-fix75: the highest ReferencedObjects index holding one of ours
local pinLost = 0                                    -- couch-fix75: pins found gone from ReferencedObjects (session total)
local clsNever = {}                                  -- class address -> true: a native / non-generated class
local clsSkip, clsSkipGen = {}, nil                  -- class address -> reason, re-decided in every world
local objSeen, objSeenN, objSeenGen = {}, 0, nil     -- object address -> true: its class was decided in this world
local OBJ_SEEN_MAX = 20000                           -- one world's distinct objects; past it the set starts again
local pinBusy = false                                -- inside the pin code: its own U.ok / getField calls do not recurse
local pinWorld = { new = 0, names = {}, gen = nil }  -- pins made since the last world's summary line
local PIN_NAMES_MAX = 10
local LSA_PATH = "/Script/Engine.LevelScriptActor"

local function pinCap()
    local n = tonumber(cfg.ClassPinCap)
    if not n or n < 1 then n = 1500 end
    return n
end

local function shortOfPath(path)
    return string.match(path, "[.:]([^.:/]+)$") or path
end

-- Append cls to GameInstance.ReferencedObjects. true = pinned (now or by an earlier Lua state), false = refused (pinBroken
-- set), nil = no GameInstance yet (retried later).
local function appendPin(cls, k, path)
    local gi = U.gi()
    if not U.ok(gi) then return nil end
    local okA, arr = pcall(getField, gi, "ReferencedObjects")  -- UGameInstance::ReferencedObjects (native member)
    if not (okA and type(arr) == "userdata") then
        pinBroken = "GameInstance.ReferencedObjects not readable"
        U.warn("util", "class pin unavailable (%s): Blueprint classes may unload and reload at a reused address "
            .. "(AUTO-152)", pinBroken)
        return false
    end
    local n = U.arrayCount(arr)
    if not pinScanned then                                     -- a hot-reloaded Lua state: the pins of the last one
        pinScanned = true
        for i = 1, n do
            local okE, o = pcall(getField, arr, i)
            if okE and U.ok(o) then
                local ok2 = U.key(o)
                if ok2 ~= 0 and not pinnedK[ok2] then pinnedK[ok2] = U.pathOf(o); pinCount = pinCount + 1; pinLastIdx = i end
            end
        end
        if pinnedK[k] then return true end
    end
    local okW, err = pcall(function() arr[n + 1] = cls end)    -- UE4SS TArray: a write one past the end appends
    local okR, back = pcall(getField, arr, n + 1)
    if not (okW and okR and U.ok(back) and U.key(back) == k) then
        pinBroken = "append refused: " .. tostr(okW and (okR and "read back " .. tostr(back) or back) or err)
        U.warn("util", "class pin of %s failed (%s): Blueprint classes may unload and reload at a reused address "
            .. "(AUTO-152)", path, pinBroken)
        return false
    end
    if n + 1 > pinLastIdx then pinLastIdx = n + 1 end
    return true, n + 1
end

-- couch-fix75 (#8 triage, long sessions): the pins only protect while they are IN GameInstance.ReferencedObjects. If the
-- game (or anything else) empties or rewrites that array, pinnedK still says "kept" and keepClass never appends the
-- class again: every class would be open to the AUTO-152 crash again for the rest of the session, silently. Checked at
-- each world turn, each phase change and right at "leaving" (BEFORE the travel's GC can unload anything): the array
-- still reaches pinLastIdx and that slot is one of ours (count + one read: cheap). Else the array is re-read and every
-- class of ours missing from it is appended again at once from its kept wrapper (U.ok + its full name unchanged = the
-- same live class); a class that is gone is forgotten (decided again on its next read). One WARN per loss. Runs with
-- pinBusy set: its own U.ok calls pin nothing.
local function checkPinsKeptInner()
    if pinCount == 0 or pinBroken or pinLastIdx == 0 or cfg.ClassPinLossCheck == false then return end
    local gi = U.gi()
    if not U.ok(gi) then return end
    local okA, arr = pcall(getField, gi, "ReferencedObjects")
    if not (okA and type(arr) == "userdata") then return end
    local n = U.arrayCount(arr)
    if n >= pinLastIdx then
        local okE, o = pcall(getField, arr, pinLastIdx)
        if okE and U.ok(o) and pinnedK[U.key(o)] then return end      -- intact (the common case)
    end
    local still, lastIdx = {}, 0
    for i = 1, n do
        local okE, o = pcall(getField, arr, i)
        if okE and U.ok(o) then
            local k = U.key(o)
            if pinnedK[k] then still[k] = true; lastIdx = i end
        end
    end
    pinLastIdx = lastIdx
    local lost, again, gone = 0, 0, 0
    local keys = {}
    for k in pairs(pinnedK) do if not still[k] then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        lost = lost + 1
        local cls, path = pinnedObj[k], pinnedK[k]
        local okF, full = false, nil
        if cls ~= nil and U.ok(cls) then okF, full = pcall(callMethod, cls, "GetFullName") end
        local same = okF and type(full) == "string" and ssub(full, -#path) == path and U.key(cls) == k
        local done = false
        if same then
            local m = U.arrayCount(arr)
            local okW = pcall(function() arr[m + 1] = cls end)
            local okR, back = pcall(getField, arr, m + 1)
            done = okW and okR and U.ok(back) and U.key(back) == k
            if done then pinLastIdx = m + 1 end
        end
        if done then
            again = again + 1
        else
            pinnedK[k], pinnedObj[k] = nil, nil
            pinCount = pinCount - 1
            gone = gone + 1
        end
    end
    if lost == 0 then return end
    pinLost = pinLost + lost
    if gone > 0 then
        pinCapped = false
        pinnedW = setmetatable({}, { __mode = "k" })
        clsSkip, clsSkipGen = {}, nil
    end
    U.warn("util", "class pins: %d of our Blueprint classes were no longer in GameInstance.ReferencedObjects (%d "
        .. "entries): %d appended again, %d gone (pinned again on their next read); %d lost this session (AUTO-152)",
        lost, n, again, gone, pinLost)
end
local function checkPinsKept(why)
    if pinBusy then return end
    pinBusy = true
    local ok, err = pcall(checkPinsKeptInner)
    pinBusy = false
    if not ok then U.logEvery("util.pinCheck", 60000, "util", "class pin check (%s) failed: %s", tostr(why), tostr(err)) end
end
U._checkPinsKept = checkPinsKept

-- Decide (and pin) one class. why = the caller's label (U.pinClass: logged) or nil (automatic: one Debug line).
-- -> true kept loaded, false never pinned (native / not pinnable / cap / refused), nil undecided (retried later)
local function keepClass(cls, why)
    if not U.ok(cls) then return false end
    local okK, k = pcall(callMethod, cls, "GetAddress")
    if not okK or type(k) ~= "number" or k == 0 then return false end
    if pinnedK[k] then return true end
    if clsNever[k] then return false end
    if clsSkipGen ~= St.worldGen then clsSkip, clsSkipGen = {}, St.worldGen end
    if clsSkip[k] then return false end
    if pinBroken then return false end
    local okF, full = pcall(callMethod, cls, "GetFullName")
    if not okF or type(full) ~= "string" then clsSkip[k] = "no name"; return false end
    local sp = sfind(full, " ", 1, true)
    local meta = sp and ssub(full, 1, sp - 1) or ""
    local path = sp and ssub(full, sp + 1) or full
    if not sfind(meta, "Class", 1, true) then clsSkip[k] = "not a class"; return false end  -- a stale cache entry
    if ssub(path, 1, 8) == "/Script/" or ssub(path, -2) ~= "_C" then clsNever[k] = true; return false end
    if sfind(path, ":", 1, true) then clsSkip[k] = "subobject class"; return false end
    local lsa = findObjectCached(LSA_PATH, 60000)
    if lsa and U.ok(lsa) then
        local okL, isL = pcall(callMethod, cls, "IsChildOf", lsa)
        if okL and isL == true then
            clsSkip[k] = "level script"
            U.dbg("util", "class pins: level script class %s left alone (it would keep its map loaded)", path)
            return false
        end
    end
    if pinCount >= pinCap() then
        clsSkip[k] = "cap"
        if not pinCapped then
            pinCapped = true
            U.warn("util", "class pins: the cap of %d Blueprint classes is reached (cfg.ClassPinCap): %s and later classes "
                .. "are NOT kept loaded and may unload and reload at a reused address (AUTO-152)", pinCap(), path)
        end
        return false
    end
    local done, n = appendPin(cls, k, path)
    if done == nil then return nil end
    if not done then return false end
    if pinnedK[k] then return true end                         -- found by the hot-reload re-scan
    pinnedK[k] = path
    pinnedObj[k] = cls
    pinCount = pinCount + 1
    pinWorld.new = pinWorld.new + 1
    if #pinWorld.names < PIN_NAMES_MAX then pinWorld.names[#pinWorld.names + 1] = shortOfPath(path) end
    if why ~= nil then
        U.log("util", "class kept loaded for the session: %s (%s; GameInstance.ReferencedObjects %d) (AUTO-152)", path,
            tostr(why), n or 0)
    else
        U.dbg("util", "class kept loaded for the session: %s (seen by name; ReferencedObjects %d)", path, n or 0)
    end
    return true
end

-- the classes the mod looked up by path (U.class / U.findLoaded caches) that are loaded now: pinned at a new world
-- before its first member read (the per-world sweep; a cache entry is re-checked by name first: stillNamed)
local function sweepCaches()
    for _, cache in ipairs({ classCache, findCache }) do
        for path, o in pairs(cache) do
            if ssub(path, -2) == "_C" and ssub(path, 1, 8) ~= "/Script/" and U.ok(o) and stillNamed(path, o) then
                keepClass(o, nil)
            end
        end
    end
end

local function worldTurn(gen)
    objSeen, objSeenN, objSeenGen = {}, 0, gen
    pcall(checkPinsKeptInner)                    -- couch-fix75 (worldTurn runs inside the pin code: pinBusy is set)
    if pinCount > 0 or pinWorld.new > 0 then
        local names = ""
        if pinWorld.new > 0 then
            names = ": " .. table.concat(pinWorld.names, ", ")
            if pinWorld.new > #pinWorld.names then names = names .. fmt(" +%d more", pinWorld.new - #pinWorld.names) end
        end
        U.log("util", "class pins: %d Blueprint classes kept loaded (+%d in the last world%s; cap %d%s) (AUTO-152)",
            pinCount, pinWorld.new, names, pinCap(), pinCapped and ", REACHED" or "")
    end
    pinWorld.new, pinWorld.names = 0, {}
    sweepCaches()
end

local function pinsOff()
    return pinBusy or pinBroken ~= nil or pinCapped or cfg.ClassPinAuto == false
end

-- o: a U.ok-valid wrapper. Never throws (it runs inside U.ok / U.getField).
local function keepObjImpl(o)
    if pinsOff() then return end
    pinBusy = true
    if objSeenGen ~= St.worldGen then pcall(worldTurn, St.worldGen) end
    local okA, a = pcall(callMethod, o, "GetAddress")
    if okA and type(a) == "number" and a ~= 0 and not objSeen[a] then
        local okC, cls = pcall(callMethod, o, "GetClass")
        local decided = true
        if okC then
            local okK, r = pcall(keepClass, cls, nil)
            decided = not okK or r ~= nil                      -- nil: no GameInstance yet, asked again next time
        end
        if decided then
            if objSeenN >= OBJ_SEEN_MAX then objSeen, objSeenN = {}, 0 end
            objSeen[a] = true
            objSeenN = objSeenN + 1
        end
    end
    pinBusy = false
end
keepObj = keepObjImpl
keepAny = function(o)
    if type(o) ~= "userdata" or pinsOff() then return end
    local ok, v = pcall(isValidOf, o)
    if ok and v == true then keepObjImpl(o) end
end

--- Keep a Blueprint class loaded for the rest of the session (see above). true when it is (now or already) pinned.
function U.pinClass(cls, why)
    if cls == nil then return false end
    local known = pinnedW[cls]
    if known ~= nil then return known end
    if pinBroken or not U.ok(cls) then return false end
    local was = pinBusy
    pinBusy = true
    local okK, r = pcall(keepClass, cls, why or "named")
    pinBusy = was
    if not okK then return false end
    if r ~= nil then pinnedW[cls] = r end
    return r == true
end

--- U.pinClass of an object's class (a live UObject wrapper; anything else is ignored).
function U.pinClassOf(o, why)
    if not U.ok(o) then return false end
    local ok, cls = pcall(callMethod, o, "GetClass")
    if not ok then return false end
    return U.pinClass(cls, why)
end

--- The class of the Blueprint function `fn` (a hooked UFunction: its outer) kept loaded.
local function pinOuterClass(fn)
    if not U.ok(fn) then return end
    local ok, cls = pcall(callMethod, fn, "GetOuter")
    if ok and U.ok(cls) then
        local was = pinBusy
        pinBusy = true
        pcall(keepClass, cls, nil)
        pinBusy = was
    end
end

function U.pinnedClasses()
    local out = {}
    for _, p in pairs(pinnedK) do out[#out + 1] = p end
    table.sort(out)
    return out, pinBroken
end

--- diag / sim: { pinned, cap, capped, broken, seen (objects decided in this world) }
function U.pinStats()
    return { pinned = pinCount, cap = pinCap(), capped = pinCapped, broken = pinBroken, seen = objSeenN, lost = pinLost }
end

--- Local players in GameInstance.LocalPlayers order: array of {lp, pc, ctrlId, index}.
--- pc may be an invalid object (LocalPlayer without controller); callers test U.ok(e.pc).
-- PER LOOP RUN CACHE (couch-racefast, live 2026-10-15: one U.localPlayers() allocates ~2.5 KB of UE4SS wrappers -
-- the GameInstance array, each LocalPlayer, its PlayerController and ControllerId - and the FAST loop's race modules
-- call it dozens of times per 33 ms tick: a large share of the ~4.5 MB/s of garbage whose GC cycles hitched random
-- module ticks 10-20 ms). Inside ONE sched.every run (St.loopSeq set by sched's loop wrapper) the list is built once;
-- each caller gets its own array copy (the entries are shared: read-only by convention). Outside a loop run (hooks,
-- one-shots) and after a CreatePlayer / RemovePlayer (join.lua: U.localPlayersForget) or a "players" event it is
-- rebuilt.
-- couch-racegc: in RACING also kept ACROSS loop runs for LP_TTL_MS inside one world (the list only changes on a
-- CreatePlayer / RemovePlayer / "players" / "world" / "phase" event, which forget it; couch.lua's pad-id swaps, which
-- change ControllerId, never run in RACING): each build was ~5 wrappers, twice per FAST + MAIN tick.
local lpCache = { seq = nil, list = nil, hits = 0, builds = 0, at = nil, world = nil }
local LP_TTL_MS = 500
function U.localPlayersForget() lpCache.seq, lpCache.list, lpCache.at = nil, nil, nil end
function U.localPlayersStats() return { hits = lpCache.hits, builds = lpCache.builds } end
local localPlayersUncached
function U.localPlayers()
    local seq = St.loopSeq
    if seq ~= nil and lpCache.list and lpCache.seq ~= seq and lpCache.at and lpCache.world == St.worldGen
        and St.phase == "RACING" and St.nowMs() - lpCache.at < LP_TTL_MS then
        lpCache.seq = seq                                     -- still fresh: this loop run reuses it
    end
    if seq ~= nil and lpCache.seq == seq and lpCache.list then
        lpCache.hits = lpCache.hits + 1
        local out, l = {}, lpCache.list
        for i = 1, #l do out[i] = l[i] end
        return out
    end
    local out = localPlayersUncached()
    lpCache.builds = lpCache.builds + 1
    if seq ~= nil then
        local keep = {}
        for i = 1, #out do keep[i] = out[i] end
        lpCache.seq, lpCache.list, lpCache.at, lpCache.world = seq, keep, St.nowMs(), St.worldGen
    else
        lpCache.seq, lpCache.list, lpCache.at = nil, nil, nil
    end
    return out
end
-- couch-fix40: the same list WITHOUT the per-caller copy, for callers that only read it (`for _, lp in
-- ipairs(U.localPlayersRO())`, U.p1): never modify the returned array or its entries. A rebuild makes a new array, so
-- an iteration in progress keeps the one it started with.
function U.localPlayersRO()
    local seq = St.loopSeq
    if seq ~= nil and lpCache.list and lpCache.seq ~= seq and lpCache.at and lpCache.world == St.worldGen
        and St.phase == "RACING" and St.nowMs() - lpCache.at < LP_TTL_MS then
        lpCache.seq = seq
    end
    if seq ~= nil and lpCache.seq == seq and lpCache.list then
        lpCache.hits = lpCache.hits + 1
        return lpCache.list
    end
    local l = U.localPlayers()                          -- builds (and keeps, inside a loop run) the list
    if seq ~= nil and lpCache.seq == seq and lpCache.list then return lpCache.list end
    return l
end
pcall(function()   -- couch-fix75: the class pins checked before a travel's GC (leaving) and at every phase change
    St.on("leaving", "util.pins", function() checkPinsKept("leaving") end)
    St.on("phase", "util.pins", function(new) checkPinsKept(new) end)
end)
pcall(function()
    St.on("players", "util.lp", function() U.localPlayersForget() end)
    St.on("world", "util.lp", function() U.localPlayersForget() end)
    St.on("phase", "util.lp", function() U.localPlayersForget() end)
end)
localPlayersUncached = function()
    local out = {}
    local gi = U.gi()
    if not U.ok(gi) then return out end
    local ok, lps = pcall(getField, gi, "LocalPlayers")            -- TArray<ULocalPlayer*>
    if not ok then return out end
    local n = U.arrayCount(lps)
    for i = 1, n do
        local okE, lp = pcall(getField, lps, i)
        if okE and U.ok(lp) then
            local pc = lp.PlayerController                         -- UPlayer.PlayerController
            local okId, cid = pcall(getField, lp, "ControllerId")          -- ULocalPlayer.ControllerId (Int)
            out[#out + 1] = { lp = lp, pc = pc, ctrlId = (okId and type(cid) == "number") and cid or (i - 1),
                              index = i }
        end
    end
    return out
end

--- P1 = the first local player's controller (ControllerId 0 by design).
function U.p1()
    local lps = U.localPlayersRO()                      -- couch-fix40: read only, no copy
    if lps[1] and U.ok(lps[1].pc) then return lps[1].pc end
    return CreateInvalidObject()
end

--- Current UWorld: P1's world, else the GameInstance's world, else UEHelpers.GetWorld() (FindAllOf inside:
--- at most once per 2 s).  VERIFY(V-CORE-04)
-- couch-racegc: cached for ONE loop run (St.loopSeq, like U.localPlayers): a UWorld does not change inside a loop run,
-- and the race modules asked for it many times per FAST tick (P1's controller + GetWorld = wrappers every time).
-- In RACING it is also kept across loop runs of the same world (St.worldGen; "world" / "leaving" / "phase" forget it):
-- no travel happens inside RACING (a travel first leaves the phase).
local worldRun = { seq = nil, w = nil, gen = nil, gs = nil }
local worldUncached
local wsRun = { gen = nil, ws = nil }                -- U.worldSettings (couch-fix40)
local function worldForget()
    worldRun.seq, worldRun.w, worldRun.gen, worldRun.gs = nil, nil, nil, nil
    wsRun.gen, wsRun.ws = nil, nil
end
function U.world()
    local seq = St.loopSeq
    local w = worldRun.w
    if seq ~= nil and w ~= nil and (worldRun.seq == seq or (St.phase == "RACING" and worldRun.gen == St.worldGen))
        and U.ok(w) then
        worldRun.seq = seq
        return w
    end
    w = worldUncached()
    if seq ~= nil and U.ok(w) then
        worldRun.seq, worldRun.w, worldRun.gen, worldRun.gs = seq, w, St.worldGen, nil
    else
        worldForget()
    end
    return w
end
--- couch-fix60 (AUTO-146): the CURRENT UWorld, never the RACING cross-run cache (a seamless travel switches the world
--- without any hook; the old UWorld can stay IsValid until the GC purges it, so the cache kept handing it out). The
--- fresh read seeds this loop run's cache: the U.world() calls after it in the same run reuse it.
function U.worldFresh()
    local w = worldUncached()
    local seq = St.loopSeq
    if seq ~= nil and U.ok(w) then
        worldRun.seq, worldRun.w, worldRun.gen, worldRun.gs = seq, w, St.worldGen, nil
    else
        worldForget()
    end
    return w
end
-- couch-fix40: the persistent level's WorldSettings, kept per world (St.worldGen; U.ok-checked at every use): wreck.lua
-- and crashcam.lua read U.world().PersistentLevel.WorldSettings every FAST tick (2 wrappers + a closure each). nil when
-- unreadable. "world" / "leaving" / "phase" forget it (worldForget).
function U.worldSettings()
    local ws = wsRun.ws
    if ws ~= nil and wsRun.gen == St.worldGen and U.ok(ws) then return ws end
    wsRun.gen, wsRun.ws = St.worldGen, nil
    local w = U.world()
    if not U.ok(w) then return nil end
    local okL, lvl = pcall(getField, w, "PersistentLevel")
    if not okL or not U.ok(lvl) then return nil end
    local okS, s = pcall(getField, lvl, "WorldSettings")
    if not okS or not U.ok(s) then return nil end
    wsRun.ws = s
    return s
end
pcall(function()
    St.on("world", "util.world", worldForget)
    St.on("leaving", "util.world", worldForget)
    St.on("phase", "util.world", worldForget)
end)
worldUncached = function()
    local p1 = U.p1()
    if U.ok(p1) then
        local ok, w = pcall(callMethod, p1, "GetWorld")
        if ok and U.ok(w) then return w end
    end
    local gi = U.gi()
    if U.ok(gi) then
        local ok, w = pcall(callMethod, gi, "GetWorld")
        if ok and U.ok(w) then return w end
    end
    local now = St.nowMs()
    if now - worldFallbackMs >= WORLD_FALLBACK_EVERY_MS then
        worldFallbackMs = now
        local ok, w = pcall(UEHelpers.GetWorld)
        if ok and U.ok(w) then return w end
    end
    return CreateInvalidObject()
end

function U.gs()
    local w = U.world()
    if not U.ok(w) then return CreateInvalidObject() end
    -- couch-racegc: kept with the cached world (RACING, same world): one wrapper per read otherwise
    if worldRun.w == w and worldRun.gs ~= nil and U.ok(worldRun.gs) then return worldRun.gs end
    local gs = w.GameState                                       -- UWorld.GameState
    if worldRun.w == w and U.ok(gs) then worldRun.gs = gs end
    return gs
end

--- AuthorityGameMode (invalid on clients).
function U.gm()
    local w = U.world()
    if not U.ok(w) then return CreateInvalidObject() end
    return w.AuthorityGameMode                                   -- UWorld.AuthorityGameMode
end

local function kslWorldBool(fnName)
    local w, ksl = U.world(), U.KSL()
    if not U.ok(w) or not U.ok(ksl) then return nil end
    -- KSL:IsServer(Object WorldContextObject)->Bool, KSL:IsStandalone(Object WorldContextObject)->Bool
    local ok, v = pcall(callMethod, ksl, fnName, w)
    if ok and type(v) == "boolean" then return v end
    return nil
end

function U.isServer()     return kslWorldBool("IsServer") == true end
function U.isStandalone() return kslWorldBool("IsStandalone") == true end

--- "standalone" | "listen" | "client" (no dedicated server in this project). "standalone" if unknown.
function U.netMode()
    local sa = kslWorldBool("IsStandalone")
    if sa == nil or sa == true then return "standalone" end
    if kslWorldBool("IsServer") == true then return "listen" end
    return "client"
end

--- GameplayStatics:GetCurrentLevelName(Object WorldContextObject, Bool bRemovePrefixString)->Str
function U.levelName()
    local w, gs = U.world(), U.GS()
    if not U.ok(w) or not U.ok(gs) then return "" end
    local ok, s = pcall(callMethod, gs, "GetCurrentLevelName", w, true)
    if ok then return U.str(s) end
    return ""
end

--- Package path of the current map, e.g. "/Game/Griffin/Maps/L_FrontEnd/L_FrontEnd" (from the world's path).
function U.currentMapPath()
    local p = U.pathOf(U.world())                  -- "/Game/.../L_X.L_X" (sub-objects after ':' cut too)
    if p == "" then return "" end
    local dot = sfind(p, ".", 1, true)
    if dot then p = ssub(p, 1, dot - 1) end
    return p
end

---------------------------------------------------------------------------------------------------- subsystems
local giSubCache = {}           -- giKey -> {path -> UObject}
local worldSubCache = {}        -- worldId -> {path -> UObject}
local findFirstTried = {}       -- worldId .. "|" .. shortName -> true

-- Identity of the current world for the per-world caches: generation (phase bumps St.worldGen on every new world,
-- also when the new UWorld reuses the old address) plus the address (a world phase has not seen yet).
local function worldId(w)
    return tostr(St.worldGen or 0) .. "@" .. tostr(U.key(w))
end

local function shortName(path)
    local s = path:match("%.([^%.]+)$") or path
    return s
end

local function subFindFirst(path)
    local k = worldId(U.world()) .. "|" .. shortName(path)
    if findFirstTried[k] then return nil end
    findFirstTried[k] = true
    local ok, o = pcall(FindFirstOf, shortName(path))
    if ok and U.ok(o) then return o end
    return nil
end

--- GameInstance subsystem by C.CLASS key (or class path). Cached per GameInstance.
--- SBL:GetGameInstanceSubsystem(Object ContextObject, Class Class)->Object   [reflect-func-all]
--- VERIFY(V-CORE-06): all five subsystems resolve; fallback cfg.SubsystemLookup = "findfirst".
function U.giSubsystem(classKey)
    local path = classPathOf(classKey)
    if not path then return CreateInvalidObject() end
    local gi = U.gi()
    if not U.ok(gi) then return CreateInvalidObject() end
    local gk = U.key(gi)
    local bucket = giSubCache[gk]
    if not bucket then giSubCache = { [gk] = {} }; bucket = giSubCache[gk] end
    local s = bucket[path]
    if s and U.ok(s) then return s end
    bucket[path] = nil
    if cfg.SubsystemLookup ~= "findfirst" then
        local sbl, cls = U.SBL(), U.class(path)
        if U.ok(sbl) and U.ok(cls) then
            local ok, o = pcall(callMethod, sbl, "GetGameInstanceSubsystem", gi, cls)
            if ok and U.ok(o) then s = o end
            if not ok then U.logEvery("gisub!" .. path, 10000, "util", "GetGameInstanceSubsystem(%s) threw: %s", path, tostr(o)) end
        end
    end
    if not s then s = subFindFirst(path) end
    if s then
        bucket[path] = s
        return s
    end
    return CreateInvalidObject()
end

--- World subsystem by C.CLASS key (or path), cached per world.
--- SBL:GetWorldSubsystem(Object ContextObject, Class Class)->Object   [reflect-func-all]
function U.worldSubsystem(classKey)
    local path = classPathOf(classKey)
    if not path then return CreateInvalidObject() end
    local w = U.world()
    if not U.ok(w) then return CreateInvalidObject() end
    local wk = worldId(w)
    local bucket = worldSubCache[wk]
    if not bucket then worldSubCache = { [wk] = {} }; bucket = worldSubCache[wk] end
    local s = bucket[path]
    if s and U.ok(s) then return s end
    bucket[path] = nil
    local sbl, cls = U.SBL(), U.class(path)
    if U.ok(sbl) and U.ok(cls) then
        local ok, o = pcall(callMethod, sbl, "GetWorldSubsystem", w, cls)
        if ok and U.ok(o) then s = o end
    end
    if not s and cfg.SubsystemLookup == "findfirst" then s = subFindFirst(path) end
    if s then
        bucket[path] = s
        return s
    end
    return CreateInvalidObject()
end

---------------------------------------------------------------------------------------------------- CSM
local CSM_ACTIVE_FN = "/Script/Griffin.CosmeticStateMachineManager:IsStateActiveByRef"   -- U.pcallFn (couch-racegc)
U.CSM_ACTIVE_FN = CSM_ACTIVE_FN
--- Is a cosmetic state active? assetKey = C.ASSET key ("CSM_PostRace", ...).
--- CosmeticStateMachineManager:IsStateActiveByRef(Object stateAsset)->Bool; fallback
--- IsStateActive(Name stateName)->Bool with C.STATE_NAME. Returns true/false, or nil if neither works.
--- VERIFY(V-HUD-05): returns booleans in pause/results; fallback cfg.HudVisibilityMode = "always".
--- findOnly = true: the state asset is only looked up in memory (StaticFindObject, never LoadAsset), for callers in
--- the MAIN/FAST polls. A state asset that is not loaded cannot be active: then the IsStateActive(Name) fallback
--- decides, else false.
function U.csmActive(assetKey, findOnly)
    local mgr = U.giSubsystem("CosmeticStateMachineManager")
    if not U.ok(mgr) then return nil end
    local path = C.ASSET[assetKey] or assetKey
    local asset
    if findOnly then
        -- cached: the FAST/MAIN polls land here several times per tick (see findObjectCached)
        local o = (type(path) == "string" and path ~= "") and findObjectCached(path) or nil
        asset = o or CreateInvalidObject()
    else
        asset = U.obj(path)
    end
    if U.ok(asset) then
        local ok, v = U.pcallFn(mgr, CSM_ACTIVE_FN, "IsStateActiveByRef", asset)
        if ok and type(v) == "boolean" then return v end
    end
    local key = type(assetKey) == "string" and assetKey:gsub("^CSM_", "") or nil
    local name = key and (C.STATE_NAME[assetKey] or C.STATE_NAME[key])
    if name then
        local ok, v = pcall(function() return mgr:IsStateActive(U.fname(name)) end)
        if ok and type(v) == "boolean" then return v end
    end
    if findOnly and not U.ok(asset) then return false end   -- not in memory = not active
    return nil
end

--- Is the state asset of assetKey in memory (StaticFindObject only, never LoadAsset)? For the polls, which map
--- U.csmActive(key, true) == false to "unknown" when the asset is not loaded (that state machine is not running).
function U.csmLoaded(assetKey)
    local path = C.ASSET[assetKey] or assetKey
    if type(path) ~= "string" or path == "" then return false end
    return findObjectCached(path) ~= nil
end

--- Find-only poll: U.csmActive(key, true), with "false because the asset is not in memory" mapped to nil (unknown).
function U.csmPoll(assetKey)
    local v = U.csmActive(assetKey, true)
    if v == false and not U.csmLoaded(assetKey) then return nil end
    return v
end

--- Is the game paused (pause CSM)? true / false / nil (unknown). Find-only, for the MAIN/FAST polls.
--- Positive test: CSM_PauseMenus_Active active. "Idle not active" is NOT a pause: the pause sub-machine runs only in
--- CSM_RF_InProgress / CSM_RF_Countdown, so after P1 finished (CSM_RF_LocalResults) Idle is loaded but inactive.
--- Fallback when Active is not resolvable: Idle inactive counts as paused only while InProgress or Countdown is
--- active (or both are unknown).
--- VERIFY(V-HUD-05): IsStateActiveByRef(CSM_PauseMenus_Active) is true while any pause page (a child state of
--- Active) is up, and false after P1 finished: in a 3P race where P1 finishes first, P2/P3 HUDs stay visible.
function U.csmPaused()
    local act = U.csmPoll("CSM_PauseActive")
    if act ~= nil then return act end
    local idle = U.csmPoll("CSM_PauseIdle")
    if idle == nil then return nil end
    if idle == true then return false end
    local ip, cd = U.csmPoll("CSM_RFInProgress"), U.csmPoll("CSM_RFCountdown")
    if ip == true or cd == true then return true end
    if ip == nil and cd == nil then return true end -- cannot tell whether the pause machine runs: old Idle rule
    return false
end

---------------------------------------------------------------------------------------------------- console
--- KSL:ExecuteConsoleCommand(Object WorldContextObject, Str Command, Object SpecificPlayer) [reflect-func-all]
--- SpecificPlayer = nil (3 args, trailing nil counts [API§9]). Returns true when the call went through.
function U.console(cmd)
    local ksl = U.KSL()
    if not U.ok(ksl) then
        U.err("util", "console '%s': KismetSystemLibrary CDO not found", tostr(cmd))
        return false
    end
    local w = U.world()
    local ctx = U.ok(w) and w or nil
    if not ctx then U.warn("util", "console '%s' without a world context", tostr(cmd)) end
    local ok, e = pcall(function() ksl:ExecuteConsoleCommand(ctx, tostr(cmd), nil) end)
    if not ok then
        U.err("util", "console '%s' failed: %s", tostr(cmd), tostr(e))
        return false
    end
    U.log("util", "console: %s", tostr(cmd))
    return true
end

--- KSL:GetConsoleVariableIntValue(Str VariableName)->Int ; nil on failure.
function U.cvarInt(name)
    local ksl = U.KSL()
    if not U.ok(ksl) then return nil end
    local ok, v = pcall(function() return ksl:GetConsoleVariableIntValue(tostr(name)) end)
    if ok and type(v) == "number" then return v end
    return nil
end

--- KSL:GetConsoleVariableFloatValue(Str VariableName)->Float ; nil on failure.
function U.cvarFloat(name)
    local ksl = U.KSL()
    if not U.ok(ksl) then return nil end
    local ok, v = pcall(function() return ksl:GetConsoleVariableFloatValue(tostr(name)) end)
    if ok and type(v) == "number" then return v end
    return nil
end

---------------------------------------------------------------------------------------------------- hooks
-- One UE4SS hook per UFunction path; any number of subscribers (one per tag) dispatched from it, each in
-- its own U.try. /Script/ paths (native): RegisterHook(path, pre, post) -> pre and post subscribers.
-- /Game/ paths (Blueprint): RegisterHook(path, cb) -> one callback AFTER the BP body [API§4]; a subscriber's
-- `post` (or, if it has none, its `pre`) runs there. RegisterHook throws when the UFunction is not in memory,
-- so the path is checked with StaticFindObject first and otherwise queued in St.pendingHooks;
-- U.retryPendingHooks() (SLOW loop + NotifyOnNewObject callbacks) registers it once the class is loaded.
---------------------------------------------------------------------------------------------------- hook thread anchor
-- 0.10.0, defense in depth. UE4SS runs every RegisterHook / NotifyOnNewObject / LoopInGameThread* / ExecuteInGameThread*
-- callback of this mod on ONE shared Lua thread (LuaMod.cpp ensure_hook_thread_exists). Its only GC anchor is the
-- registry ref handed to the registration that created it (make_hook_state; later callers get LUA_REFNIL). If that
-- registration is ever released (native hook removed, NotifyOnNewObject callback returning true), the GC may free the
-- thread while callbacks keep running on it (upstream RE-UE4SS issue #1345). In this mod the creator is the permanent
-- gfx hook (1,2), so it does not happen today (notes/research/ue4ss-hook-thread-gc.md §2); the 13_27_33 crash was the
-- keybind race fixed by keyq.lua. We still keep our own strong reference to every non-main thread a callback runs on
-- (sched wrappers + the hook dispatcher call this). VERIFY(V-CORE-12): "hook thread anchored by the mod (UE4SS
-- registry anchor present)" once per session, and a WARN if UE4SS later drops its anchor (U.checkThreadAnchor). The
-- registry walk can miss a key that another thread inserts mid-walk; with keyq no other thread inserts after load.
local anchoredThreads = {}
_G.SWGRCouch_hookThreads = anchoredThreads
local anchorWatch = { thread = nil, inRegistry = nil, dropped = false, lastCheckMs = nil }

local function registryHolds(co)
    local ok, found = pcall(function()
        for _, v in pairs(debug.getregistry()) do
            if v == co then return true end
        end
        return false
    end)
    return ok and found == true
end

function U.anchorThread()
    St.cb = (St.cb or 0) + 1                    -- 0.12.0: a new callback (St.launchHold)
    local co, isMain = coroutine.running()
    if co == nil or isMain or anchoredThreads[co] then return end
    anchoredThreads[co] = true
    anchorWatch.thread = co
    anchorWatch.inRegistry = registryHolds(co)
    U.log("core", "hook thread anchored by the mod (UE4SS registry anchor %s) (V-CORE-12)",
        anchorWatch.inRegistry and "present" or "MISSING")
end

-- SLOW loop, every 30 s: one WARN when UE4SS's own anchor disappears (the mod's reference keeps the thread alive).
function U.checkThreadAnchor()
    local co = anchorWatch.thread
    if co == nil or anchorWatch.dropped or anchorWatch.inRegistry ~= true then return end
    local now = St.nowMs()
    if anchorWatch.lastCheckMs and now - anchorWatch.lastCheckMs < 30000 then return end
    anchorWatch.lastCheckMs = now
    if not registryHolds(co) then
        anchorWatch.dropped = true
        U.warn("core", "UE4SS released its registry anchor of the shared hook thread; the mod's own reference keeps it alive (V-CORE-12)")
    end
end

-- Callback params are RemoteUnrealParams (use :get()). Dispatchers always return nil (no return override).
local hookSubs = {}     -- path -> array of {tag=, pre=, post=}
local hookFailed = {}   -- path -> error text (UFunction exists but is not hookable: never retried)

local function isNativePath(path) return ssub(path, 1, 8) == "/Script/" end

local function dispatch(path, which, ...)
    U.anchorThread()
    local list = hookSubs[path]
    if not list then return nil end
    for i = 1, #list do
        local s = list[i]
        local fn
        if which == "bp" then fn = s.post or s.pre else fn = s[which] end
        if fn then U.try(s.tag .. "@" .. which, fn, ...) end
    end
    return nil
end

local function registerNow(path)
    if St.hooks[path] then return true end
    if hookFailed[path] then return false end
    -- cached with a short miss TTL: pending race-UI classes re-checked raw every SLOW tick were the
    -- once-per-second menu hitch; 2.5 s still arms a freshly loaded class fast enough for the pause bridge
    local fnObj = findObjectCached(path, 2500)
    if not fnObj then return false end                           -- not loaded yet: stays pending
    local ok, preId, postId
    if isNativePath(path) then
        ok, preId, postId = pcall(RegisterHook, path,
            function(...) return dispatch(path, "pre", ...) end,
            function(...) return dispatch(path, "post", ...) end)
    else
        ok, preId, postId = pcall(RegisterHook, path,
            function(...) return dispatch(path, "bp", ...) end)
    end
    if not ok then
        hookFailed[path] = tostr(preId)
        St.pendingHooks[path] = nil
        U.err("hook", "RegisterHook(%s) failed: %s", path, tostr(preId))
        return false
    end
    St.hooks[path] = { pre = preId, post = postId }
    St.pendingHooks[path] = nil
    -- couch-fix67 (AUTO-152): a hooked Blueprint function's class stays loaded (its callbacks read its members by name)
    if not isNativePath(path) then pinOuterClass(fnObj) end
    U.log("hook", "registered %s (%s, ids %s/%s)", path, isNativePath(path) and "native" or "bp", tostr(preId), tostr(postId))
    return true
end

-- rel103 (hook audit 2026-10-24, notes/hook-audit/HOOK-AUDIT.md finding A): this game's UE4SS prints at every start
-- "ProcessLocalScriptFunction is not available": a RegisterHook on a Blueprint (/Game/) UFunction returns ids and the
-- callback NEVER runs (0 fires in ~300 sessions). U.hook refuses /Game/ paths while that line is in UE4SS.log
-- (cfg.BlueprintHooks "auto"; "on" = register anyway, "off" = always refuse), with ONE WARN naming them, so a feature
-- can never again rely on a silent hook. Natives (/Script/) are not affected. The simulator has no UE4SS.log: "auto"
-- registers there as before.
local bpDead = nil                                    -- nil = not decided yet
local bpRefused, bpWarned = {}, false
local function bpHooksDead()
    if bpDead ~= nil then return bpDead end
    local mode = cfg.BlueprintHooks
    if mode == "on" or mode == true then bpDead = false; return false end
    if mode == "off" or mode == false then bpDead = true; return true end
    bpDead = false
    pcall(function()
        local okS, S = pcall(require, "settings")
        local dir = okS and type(S) == "table" and type(S.modDir) == "function" and S.modDir() or nil
        if type(dir) ~= "string" then return end
        local f = io.open(dir .. "/../../UE4SS.log", "rb")
        if not f then return end
        local head = f:read(400000) or ""
        f:close()
        if sfind(head, "ProcessLocalScriptFunction is not available", 1, true) then bpDead = true end
    end)
    return bpDead
end
U.bpHooksDead = bpHooksDead
function U.bpHooksRefused() return bpRefused end
function U._bpReset() bpDead, bpRefused, bpWarned = nil, {}, false end   -- tests

--- Subscribe to a UFunction. spec = {pre = fn, post = fn}. Returns true when the UE4SS hook is in place,
--- false when queued (or failed). A second call with the same path and tag replaces that subscriber.
--- VERIFY(V-CORE-07): BP hooks fire (log lines from tab click, button click, Go).
function U.hook(path, spec, tag)
    tag = tag or "hook"
    if type(path) ~= "string" or type(spec) ~= "table" or (type(spec.pre) ~= "function" and type(spec.post) ~= "function") then
        U.err("hook", "U.hook(%s, spec, %s): bad arguments", tostr(path), tostr(tag))
        return false
    end
    if ssub(path, 1, 6) == "/Game/" and bpHooksDead() then
        if not bpRefused[path] then
            bpRefused[path] = tag
            if not bpWarned then
                bpWarned = true
                U.warn("hook", "Blueprint hooks refused: UE4SS.log says ProcessLocalScriptFunction is not available, so a "
                    .. "hook on a /Game/ function would never fire (cfg.BlueprintHooks; hook audit 2026-10-24). First: %s (%s)",
                    path, tostr(tag))
            else
                U.dbg("hook", "Blueprint hook refused (never fires in this UE4SS): %s (%s)", path, tostr(tag))
            end
        end
        return false
    end
    local list = hookSubs[path]
    if not list then list = {}; hookSubs[path] = list end
    local entry = { tag = tag, pre = spec.pre, post = spec.post }
    local replaced = false
    for i = 1, #list do
        if list[i].tag == tag then list[i] = entry; replaced = true; break end
    end
    if not replaced then list[#list + 1] = entry end
    if St.hooks[path] then return true end
    if hookFailed[path] then return false end
    local ok, done = pcall(registerNow, path)
    if ok and done then return true end
    if not hookFailed[path] and not St.pendingHooks[path] then
        St.pendingHooks[path] = { spec = spec, tag = tag, sinceMs = St.nowMs(), tries = 0 }
        U.dbg("hook", "queued %s (%s): UFunction not loaded yet", path, tag)
    end
    return false
end

--- Try every queued hook again (cheap: one StaticFindObject per pending path).
function U.retryPendingHooks()
    for path, p in pairs(St.pendingHooks) do
        p.tries = (p.tries or 0) + 1
        local ok, e = pcall(registerNow, path)
        if not ok then U.err("hook", "retry %s: %s", path, tostr(e)) end
        if St.pendingHooks[path] and p.tries % 60 == 0 then
            U.dbg("hook", "still pending after %d tries: %s", p.tries, path)
        end
    end
end

--- Unregister everything (ModRef.OnUnload). Subscribers and the queue are cleared too.
function U.unhookAll()
    for path, ids in pairs(St.hooks) do
        local ok, e = pcall(UnregisterHook, path, ids.pre, ids.post)
        if not ok then U.warn("hook", "UnregisterHook(%s): %s", path, tostr(e)) end
    end
    St.hooks = {}
    St.pendingHooks = {}
    hookSubs = {}
    hookFailed = {}
end

--- path -> "registered" | "pending" | "failed: <msg>" (diag).
function U.hookStatus()
    local out = {}
    for path in pairs(hookSubs) do
        if St.hooks[path] then out[path] = "registered"
        elseif hookFailed[path] then out[path] = "failed: " .. hookFailed[path]
        else out[path] = "pending" end
    end
    return out
end

return U
