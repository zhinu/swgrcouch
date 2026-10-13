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

function U.try(tag, fn, ...)
    trace("try", tag)
    if type(fn) ~= "function" then
        U.err(tag, "U.try: not a function (%s)", type(fn))
        return false
    end
    local r = table.pack(xpcall(fn, debug.traceback, ...))
    if not r[1] then
        U.err(tag, "%s", tostr(r[2]))
        return false
    end
    return table.unpack(r, 1, r.n)
end

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
    local r = table.pack(xpcall(fn, debug.traceback, ...))
    if r[1] then return table.unpack(r, 1, r.n) end
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
function U.ok(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
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
    return pcall(function() return ksl:CallFunction(KSL_ISVALID, o) end)
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
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and type(a) == "number" then return a end
    return 0
end

--- Both valid and the same object (UE4SS `==` compares pointers [API§7]).
function U.same(a, b)
    return U.ok(a) and U.ok(b) and a == b
end

---------------------------------------------------------------------------------------------------- values
--- Unwrap a RemoteUnrealParam / LocalUnrealParam (hook params, TArray-return elements); other values pass.
local function unwrapParam(v)
    if type(v) ~= "userdata" then return v end
    local ok, t = pcall(function() return v:type() end)
    if ok and (t == "RemoteUnrealParam" or t == "LocalUnrealParam") then
        local ok2, inner = pcall(function() return v:get() end)
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
    local ok, s = pcall(function() return v:ToString() end)
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
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if not ok or type(n) ~= "number" then return out end
    for i = 1, n do
        local okE, v = pcall(function() return arr[i] end)
        if okE then out[#out + 1] = unwrapParam(v) end
    end
    return out
end

--- Element count of a TArray userdata or a Lua table; 0 otherwise.
function U.arrayCount(arr)
    if type(arr) == "table" then return #arr end
    if type(arr) ~= "userdata" then return 0 end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    return 0
end

--- Object path without the class prefix: GetFullName() = "<Class> <path>" [API§7]. "" when invalid.
function U.pathOf(obj)
    if not U.ok(obj) then return "" end
    local ok, full = pcall(function() return obj:GetFullName() end)
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
    if o ~= nil and U.ok(o) then return o end
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

--- Cached find-only lookup (never LoadAsset) for per-tick polls; nil while the object is not in memory.
--- missTtl (ms, default 10000) = how long a miss is trusted before the next real StaticFindObject.
function U.findLoaded(path, missTtl)
    if type(path) ~= "string" or path == "" then return nil end
    return findObjectCached(path, missTtl)
end

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
    return found == true
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
    if c and U.ok(c) then return c end
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
    if o and U.ok(o) then return o end
    objCache[path] = nil
    o = findObject(path)
    if not o and tryLoad(path) then o = findObject(path) end
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
    local ok, v = pcall(function() return o:IsA(cls) end)
    return ok and v == true
end

function U.isVehicle(pawn)        return U.isA(pawn, "VehiclePawn") end
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

--- Local players in GameInstance.LocalPlayers order: array of {lp, pc, ctrlId, index}.
--- pc may be an invalid object (LocalPlayer without controller); callers test U.ok(e.pc).
function U.localPlayers()
    local out = {}
    local gi = U.gi()
    if not U.ok(gi) then return out end
    local ok, lps = pcall(function() return gi.LocalPlayers end)   -- TArray<ULocalPlayer*>
    if not ok then return out end
    local n = U.arrayCount(lps)
    for i = 1, n do
        local okE, lp = pcall(function() return lps[i] end)
        if okE and U.ok(lp) then
            local pc = lp.PlayerController                         -- UPlayer.PlayerController
            local okId, cid = pcall(function() return lp.ControllerId end)   -- ULocalPlayer.ControllerId (Int)
            out[#out + 1] = { lp = lp, pc = pc, ctrlId = (okId and type(cid) == "number") and cid or (i - 1),
                              index = i }
        end
    end
    return out
end

--- P1 = the first local player's controller (ControllerId 0 by design).
function U.p1()
    local lps = U.localPlayers()
    if lps[1] and U.ok(lps[1].pc) then return lps[1].pc end
    return CreateInvalidObject()
end

--- Current UWorld: P1's world, else the GameInstance's world, else UEHelpers.GetWorld() (FindAllOf inside:
--- at most once per 2 s).  VERIFY(V-CORE-04)
function U.world()
    local p1 = U.p1()
    if U.ok(p1) then
        local ok, w = pcall(function() return p1:GetWorld() end)
        if ok and U.ok(w) then return w end
    end
    local gi = U.gi()
    if U.ok(gi) then
        local ok, w = pcall(function() return gi:GetWorld() end)
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
    return w.GameState                                           -- UWorld.GameState
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
    local ok, v = pcall(function() return ksl[fnName](ksl, w) end)
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
    local ok, s = pcall(function() return gs:GetCurrentLevelName(w, true) end)
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
            local ok, o = pcall(function() return sbl:GetGameInstanceSubsystem(gi, cls) end)
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
        local ok, o = pcall(function() return sbl:GetWorldSubsystem(w, cls) end)
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
        local ok, v = pcall(function() return mgr:IsStateActiveByRef(asset) end)
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
    if not findObjectCached(path, 2500) then return false end   -- not loaded yet: stays pending
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
    U.log("hook", "registered %s (%s, ids %s/%s)", path, isNativePath(path) and "native" or "bp", tostr(preId), tostr(postId))
    return true
end

--- Subscribe to a UFunction. spec = {pre = fn, post = fn}. Returns true when the UE4SS hook is in place,
--- false when queued (or failed). A second call with the same path and tag replaces that subscriber.
--- VERIFY(V-CORE-07): BP hooks fire (log lines from tab click, button click, Go).
function U.hook(path, spec, tag)
    tag = tag or "hook"
    if type(path) ~= "string" or type(spec) ~= "table" or (type(spec.pre) ~= "function" and type(spec.post) ~= "function") then
        U.err("hook", "U.hook(%s, spec, %s): bad arguments", tostr(path), tostr(tag))
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
