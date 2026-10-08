-- SWGRCouch · inputfix.lua (input isolation: each human car obeys only its own player's devices)
-- Research and every address below: notes/research/input-isolation.md.
--
-- WHY ONE DEVICE DROVE BOTH CARS (first split race 2026-10-07, static analysis of build 381121):
--  1. A car's analog input (steer/throttle/brake/boost, pitch, camera) is read by UPlayerInputComponent through
--     UGfnRawInputSubsystem::GetActionValue (0x143a07d1a), from the subsystem in the component's weak pointer
--     PlayerInputComponent.RawInputSubsystem (+0xc0). The component's setup (0x1430963bc) fills that pointer with
--     GetWorld()->OwningGameInstance->LocalPlayers[0]'s subsystem: EVERY human car reads P1's subsystem.
--  2. Each UGfnRawInputSubsystem registers its own Slate input pre-processor ("GfnRawInput", vtable 0x14991a9c0).
--     Its KeyDown/KeyUp/Analog/MouseButton handlers store the FKey's value and ignore FInputEvent::UserIndex, so
--     every subsystem records every keyboard, mouse and pad. (Gamepad FKeys are the same for all pads.)
--  3. Buttons bound through Enhanced Input on the car's InputComponent (ChangeBoost, Boost press, ChangeCamera,
--     throttle toggle) and the BP IA_Veh_* events (pre-flight checks, pause) are routed per ControllerId by the
--     engine: they were already per player.
-- So fixing (1) alone is not enough. This module does, in race phases, polled (no BP hook needed):
--  BIND    each local human car's PlayerInputComponent.RawInputSubsystem := its own PC.RawInputSubsystem;
--          a guest subsystem without any vehicle mapping context gets the vehicle pad IMC ("fill").
--  NATIVE  loads native/swgr_inputfilter.dll (package.loadlib(path, "*"): DllMain only, no Lua C API). It wraps
--          5 handler slots of the pre-processor vtable and drops an event for a processor whose owner is not the
--          event's user (owner table written by this module to swgr_inputfilter.cfg). Full isolation, any devices.
--  KBSPLIT Lua-only fallback when the DLL is not active: the raw subsystems' ActiveMappingContexts are filtered by
--          device class (IMC_Vehicle_Keyboard = keyboard+mouse only; IMC_Vehicle_Default/Alternative = pad only):
--          guests lose the keyboard IMC, and with KeyboardIsP1 P1 loses the pad IMCs. That isolates keyboard vs
--          pads; two PADS still share input without the DLL (logged once as a warning).
-- Config (cfg.<key>, defaults here when config.lua lacks the key): InputFixMode "auto"|"native"|"kbsplit"|"bind"|
-- "off", InputFixNativeScope "race"|"always", InputFixGuestContexts "fill"|"leave", InputFixKbSplitP1 "kbp1"|
-- "always"|"never", InputFixOwnLoopMs (0 = only when main calls inputfix.tick), InputFixDiagEveryMs.
--
-- PHOTO MODE (run E: "photo mode was not mapped to the gamepad"), static research 2026-10-07: the PhotoMode plugin does
-- NOT read UGfnRawInputSubsystem. APhotoModePawn binds Enhanced Input (FreeCam/OrbitCam/AltOrbitCam IMCs + IA_* actions
-- as UPROPERTYs, reflect.tsv), UPhotoModeHUDWidget is a CommonActivatableWidget with its own actions, the entry is
-- IMC_PhotoModeTriggerable / IA_EnterPhotoMode (DefaultGame.ini [PhotoModeConfigSettings], priority 1000), and
-- UPhotoModeManager::EnterPhotoMode() has no player parameter: it puts EVERY tracked local player into photo mode
-- (run E: both PCs possessed a BP_PhotoModePawn_C), one HUD per player (GetHudWidgetForPlayer(pc)). Enhanced Input is
-- routed per ControllerId by the engine, so each pad drives its own photo camera in its own view; the native filter
-- (raw subsystem only, returns "not handled") cannot block it. Run E's dead pad was P2's view being held on the
-- spectator camera by wreck.lua's view guard (it re-set P2's view target every 2 s) on a faded-out view. inputfix only
-- backs off while photo mode is open (filter off, no context edits) and logs pawn + photo HUD per player.
--
-- VERIFY ids (README §9 style):
--  V-INP-01 after the countdown, diag "inputfix" shows every human car bound=own (car subsystem == pc subsystem).
--  V-INP-02 guest subsystems list a vehicle IMC (ctx=...pad) without "filled"; if "filled", the guest still steers.
--  V-INP-03 native status: installed=1 reason=ok; while racing, o ctrl=1 shows passed>0 and dropped>0.
--  V-INP-04 TArray writes on ActiveMappingContexts stick (kbsplit/fill) and the game does not put them back each
--           frame (the "reapplied" counter stays small).
--  V-INP-05 package.loadlib exists in UE4SS's Lua (LUA_DL_DLL, luaL_openlibs) and Wine loads the DLL.
--  V-INP-06 Slate UserIndex: keyboard/mouse = 0, XInput pad k = k (the viewport's own routing, as join.lua sees it).
--  V-INP-07 photo mode: "photo mode open: native filter off (ctrl 0 pawn BP_PhotoModePawn_C hud ..., ctrl 1 ...)",
--           each pad moves its own photo camera; "photo mode closed" afterwards and the cars are bound again.
--  V-INP-08 (0.6.0, live finding F1 of run G) every guest's Enhanced Input gets P1's vehicle pad IMC: "P2 Enhanced
--           Input: IMC_Vehicle_Default added" + "verified: 19 IA_Veh_* ..." (section "guest Enhanced Input" below).
--           Config: InputFixGuestEnhanced "add"|"off", InputFixGuestEnhancedPriority (1, used when P1's priority is not
--           readable), InputFixGuestEnhancedRemove (true: removed again in the front end).
-- Revision 2026-10-07 (run E): the bind check compares ADDRESSES (weak pointer -> object -> GetAddress), accepts the
-- PC's or the LocalPlayer's subsystem, waits NATIVE_GRACE_MS for the DLL copy ("pending") before it reports a car as
-- unbound, stops the failing Lua weak-pointer write after its first error, and logs the all-bound edge.

local cfg = require("config")
local St = require("state")
local U = require("util")
local sched = require("sched")

local M = {}
local TAG = "inputfix"

local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local MODES = { auto = true, native = true, kbsplit = true, bind = true, off = true }
local function mode()
    local m = opt("InputFixMode", "auto")
    return MODES[m] and m or "auto"
end

local DLL_NAME = "swgr_inputfilter.dll"
local CFG_NAME = "swgr_inputfilter.cfg"
local STATUS_NAME = "swgr_inputfilter.status"

-- private state (diag reads it through M.diagLines)
St.inputfix = St.inputfix or {}
local S = St.inputfix
S.native = S.native or { tried = false, loaded = false, err = nil, dir = nil, lastCfg = nil, seq = 0, status = {} }
S.native.writes = S.native.writes or {}   -- carKey -> { tag, dst, src }: DLL copies the PC weak ptr (live fix)
S.native.wTag = S.native.wTag or 0
S.cars = S.cars or {}          -- [carKey] = { pcKey, ctrlId, bound = bool, lastResult }
S.counts = S.counts or { bind = 0, bindFail = 0, ctxApplied = 0, ctxFilled = 0 }
S.imcKind = S.imcKind or {}     -- [imcKey] = "kb" | "pad" | "mixed" | "other"
S.padImcs = S.padImcs or {}     -- [imcKey] = imc object (vehicle pad IMCs seen on any raw subsystem)
S.warned = S.warned or {}

local bindAll                   -- forward declaration (defined with tick)

---------------------------------------------------------------------------------------------------- helpers
local function nm(o)
    if not U.ok(o) then return "nil" end
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end

local function weakGet(v)
    if v == nil then return nil end
    local ok, o = pcall(function() return v:Get() end)
    if ok and o ~= nil then return o end
    return v
end

-- Address of a UObject or of the object a TWeakObjectPtr value points to; 0 when unresolved. Run E 2026-10-07: the
-- check compared wrappers/weak values and logged "write did not stick" / "not bound" although the DLL's weak-pointer
-- copy had worked. Everything below compares ADDRESSES only.
local function addrOf(v)
    if v == nil then return 0 end
    local k = U.key(weakGet(v))
    if k ~= 0 then return k end
    return U.key(v)
end

-- Photo mode open (phase.photoMode, shared detection): inputfix backs off (no context edits, native filter off).
local function photoActive()
    local ok, ph = pcall(U.mod, "phase")
    if ok and type(ph) == "table" and type(ph.photoMode) == "function" then
        local ok2, v = pcall(ph.photoMode)
        return ok2 and v == true
    end
    return false
end

local function isRacePhase()
    local p = St.phase
    return p == "LOADING" or p == "PRERACE" or p == "RACING" or p == "POSTRACE"
end

local function keyboardIsP1()
    local ok, v = pcall(function() return require("settings").get("KeyboardIsP1") end)
    return ok and v == true
end

-- bOffsetPlayerGamepadIds as the engine sees it (split.lua sets it from KeyboardIsP1).
local function padOffset()
    local ok, v = pcall(function() return U.GMS().bOffsetPlayerGamepadIds end)
    if ok and type(v) == "boolean" then return v end
    return keyboardIsP1()
end

-- Device class of a mapping context: by name first (the three vehicle IMCs), else by its keys.
-- IMC_Vehicle_Keyboard: keyboard + mouse keys only; IMC_Vehicle_Default/_Alternative: Gamepad_* only (decoded
-- assets, input-isolation.md §4).
local function imcKind(imc)
    local k = U.key(imc)
    if k == 0 then return "other" end
    if S.imcKind[k] then return S.imcKind[k] end
    local name = nm(imc)
    local kind
    if name:find("Keyboard", 1, true) then kind = "kb"
    elseif name:find("IMC_Vehicle_", 1, true) then kind = "pad"
    else
        local pad, other = 0, 0
        pcall(function()
            imc.DefaultKeyMappings.Mappings:ForEach(function(_, e)
                local kn = e:get().Key.KeyName:ToString()
                if kn:sub(1, 8) == "Gamepad_" then pad = pad + 1 else other = other + 1 end
            end)
        end)
        if pad > 0 and other == 0 then kind = "pad"
        elseif other > 0 and pad == 0 then kind = "kb"
        elseif pad > 0 then kind = "mixed"
        else kind = "other" end
        -- only vehicle-like contexts matter here; others (UI, spectator) are never touched
        if not name:find("Vehicle", 1, true) and kind ~= "mixed" then kind = "other" end
    end
    S.imcKind[k] = kind
    if kind == "pad" then S.padImcs[k] = imc end
    return kind
end

-- ActiveMappingContexts of a raw subsystem as a Lua array of UObjects.
local function ctxList(sub)
    local out = {}
    pcall(function()
        sub.ActiveMappingContexts:ForEach(function(_, e)
            local o = e:get()
            if U.ok(o) then out[#out + 1] = o end
        end)
    end)
    return out
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if addrOf(a[i]) == 0 or addrOf(a[i]) ~= addrOf(b[i]) then return false end end
    return true
end

-- VERIFY(V-INP-04): Empty() + 1-based writes (LuaTArray grows with AddZeroed).
local function setCtxList(sub, list)
    return U.try(TAG, function()
        local arr = sub.ActiveMappingContexts
        arr:Empty()
        for i = 1, #list do arr[i] = list[i] end
    end)
end

local function ctxNames(list)
    local t = {}
    for i = 1, #list do t[#t + 1] = nm(list[i]) .. "/" .. imcKind(list[i]) end
    return table.concat(t, ",")
end

-- ORIGINAL LISTS. UGfnRawInputSubsystem is a LocalPlayerSubsystem: it outlives the race (P1's lives as long as the
-- process, guests are never removed), so kbsplit/fill edits would stay for the rest of the session (a later solo pad
-- race could lose IMC_Vehicle_Default on P1). Each subsystem's list is saved before our first write and written back
-- on FRONTEND, but ONLY when the list still is exactly what we last wrote (if the game rewrote it meanwhile, the game
-- owns it again and it is left alone). Paths are taken here (game thread) so persistShared (OnUnload, not on the
-- game thread) can save them as strings for a hot reload.
S.ctxSaved = S.ctxSaved or {}   -- [subKey] = { sub, orig = {imc}, origPaths, writtenPaths }

local function pathsOf(list)
    local t = {}
    for i = 1, #list do t[i] = U.pathOf(list[i]) end
    return t
end

local function samePaths(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- setCtxList + bookkeeping of the original list (first write only).
local function writeCtx(sub, cur, want)
    local k = U.key(sub)
    local rec = S.ctxSaved[k]
    if not rec then
        rec = { sub = sub, orig = cur, origPaths = pathsOf(cur) }
        S.ctxSaved[k] = rec
    end
    rec.sub = sub
    local ok = setCtxList(sub, want)
    if ok then rec.writtenPaths = pathsOf(want) end
    return ok
end

--- FRONTEND (game thread): give every edited raw subsystem its original mapping contexts back.
function M.restoreContexts()
    local live = {}
    for _, e in ipairs(U.localPlayers()) do
        pcall(function()
            local sub = e.pc.RawInputSubsystem
            if U.ok(sub) then live[U.key(sub)] = sub end
        end)
    end
    for k, rec in pairs(S.ctxSaved) do
        U.try(TAG, function()
            local sub = U.ok(rec.sub) and rec.sub or live[k]
            if not U.ok(sub) or not rec.writtenPaths then return end
            local cur = ctxList(sub)
            if not samePaths(pathsOf(cur), rec.writtenPaths) then
                U.log(TAG, "raw contexts of %s changed since our edit (the game rewrote them): left as is", nm(sub))
                return
            end
            local orig = {}
            for i, path in ipairs(rec.origPaths) do
                local o = rec.orig and rec.orig[i]
                if not U.ok(o) then
                    local okF, f = pcall(StaticFindObject, path)
                    o = okF and f or nil
                end
                if not U.ok(o) then error("original context not found: " .. tostring(path)) end
                orig[#orig + 1] = o
            end
            if setCtxList(sub, orig) then
                U.log(TAG, "raw contexts of %s restored: {%s}", nm(sub), ctxNames(orig))
            end
        end)
    end
    S.ctxSaved = {}
end

-- Hot reload: scalars only (addresses + paths), see main.lua §6.
function M.persistShared(put)
    local n = 0
    for k, rec in pairs(S.ctxSaved) do
        if rec.writtenPaths and k ~= 0 then
            n = n + 1
            put("inputfix.ctx." .. n, string.format("%d|%s|%s", k, table.concat(rec.origPaths, ","),
                table.concat(rec.writtenPaths, ",")))
        end
    end
    put("inputfix.ctx.n", n)
    local m = 0
    for k, rec in pairs(S.ei) do
        if rec.ours and rec.imcPath and k ~= 0 then
            m = m + 1
            put("inputfix.ei." .. m, string.format("%d|%s|%d", k, rec.imcPath, rec.pnum or 0))
        end
    end
    put("inputfix.ei.n", m)
end

function M.restoreShared(get)
    local n = get("inputfix.ctx.n")
    if type(n) ~= "number" then return end
    local function split(str)
        local t = {}
        for x in str:gmatch("[^,]+") do t[#t + 1] = x end
        return t
    end
    for i = 1, n do
        local v = get("inputfix.ctx." .. i)
        local k, o, w = type(v) == "string" and v:match("^(%d+)|([^|]*)|([^|]*)$")
        if k then
            S.ctxSaved[tonumber(k)] = { origPaths = split(o), writtenPaths = split(w) }
        end
    end
    if n > 0 then U.log(TAG, "hot reload: %d edited raw context list(s) to restore in the front end", n) end
    local m = get("inputfix.ei.n")
    if type(m) ~= "number" then return end
    for i = 1, m do
        local v = get("inputfix.ei." .. i)
        local k, path, pn = type(v) == "string" and v:match("^(%d+)|([^|]*)|(%d+)$")
        if k then
            S.ei[tonumber(k)] = { ours = true, imcPath = path, pnum = tonumber(pn), adds = 1, state = "pending",
                                  addAt = St.nowMs() }
        end
    end
    if m > 0 then
        U.log(TAG, "hot reload: %d guest Enhanced Input context(s) added by the mod (removed in the front end)", m)
    end
end

---------------------------------------------------------------------------------------------------- native filter
local function modDir()
    local ok, d = pcall(function() return require("settings").modDir() end)
    if ok and type(d) == "string" and d ~= "" then return (d:gsub("\\", "/")) end
    return nil
end

local function nativeDir()
    if S.native.dir then return S.native.dir end
    local d = modDir()
    if d then S.native.dir = d .. "/native" end
    return S.native.dir
end

local function fileExists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

-- Writes the cfg only when its text changes (the DLL reloads on a changed write time).
local function writeNativeCfg(text)
    local dir = nativeDir()
    if not dir or text == S.native.lastCfg then return end
    local f, err = io.open(dir .. "/" .. CFG_NAME, "w")
    if not f then
        U.logEvery("inputfix.cfgw", 10000, TAG, "cannot write %s/%s: %s", dir, CFG_NAME, tostring(err))
        return
    end
    f:write(text)
    f:close()
    S.native.lastCfg = text
end

local function readNativeStatus()
    local dir = nativeDir()
    if not dir then return S.native.status end
    local f = io.open(dir .. "/" .. STATUS_NAME, "r")
    if not f then return S.native.status end
    local st = { owners = {} }
    for line in f:lines() do
        local k, v = line:match("^(%w[%w_]*)=(.*)$")
        if k then st[k] = v
        elseif line:sub(1, 2) == "o " then st.owners[#st.owners + 1] = line:sub(3) end
    end
    f:close()
    S.native.status = st
    return st
end

local function nativeActive()
    return S.native.loaded and S.native.status.installed == "1"
end

local function nativeWanted()
    local m = mode()
    return m == "auto" or m == "native"
end

-- Owner table + switches for the DLL. enabled only in race phases unless InputFixNativeScope = "always".
-- GATED ON THE BIND (race phases): a car reads LocalPlayers[0]'s raw subsystem until bindCar re-points it. With
-- the filter on and a car NOT bound, that car (P2's) still reads P1's subsystem, which now drops every pad-2 event:
-- P1 would drive both cars and P2's pad nothing (worse than no filter). So while any local car is unbound (S.allBound
-- false, computed by bindAll), enabled=0. VERIFY(V-INP-01): "native filter held off" never stays in the log; if it
-- does, the bind does not work in this build: use InputFixMode = "off".
local function buildNativeCfg(players)
    local on = nativeWanted() and (opt("InputFixNativeScope", "race") == "always" or isRacePhase())
    if on and isRacePhase() and S.allBound == false then on = false end
    if on and S.photo == true then on = false end      -- photo mode: every processor records every device again
    local lines = {
        "# written by SWGRCouch inputfix.lua; read by swgr_inputfilter.dll",
        "enabled=" .. (on and "1" or "0"),
        "offset=" .. (padOffset() and "1" or "0"),
        "seq=" .. tostring(S.native.seq),
    }
    for _, p in ipairs(players) do
        local a = U.key(p.sub)
        if a ~= 0 then lines[#lines + 1] = string.format("p %d 0x%x", p.ctrlId, a) end
    end
    for _, w in pairs(S.native.writes) do
        lines[#lines + 1] = string.format("wo %d 0x%x 0x%x", w.tag, w.dst, w.obj)
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Loads the DLL once per Lua state (a reload calls loadlib again: same module, DllMain does not run twice).
-- VERIFY(V-INP-05)
local function loadNative(players)
    if S.native.tried then return S.native.loaded end
    S.native.tried = true
    local dir = nativeDir()
    if not dir then S.native.err = "mod dir unknown"; return false end
    local path = dir .. "/" .. DLL_NAME
    if not fileExists(path) then
        S.native.err = "missing " .. path
        U.warn(TAG, "native filter not installed (%s): falling back to kbsplit", path)
        return false
    end
    if not (package and type(package.loadlib) == "function") then
        S.native.err = "package.loadlib unavailable"
        U.warn(TAG, "package.loadlib is not available in this Lua state: falling back to kbsplit")
        return false
    end
    writeNativeCfg(buildNativeCfg(players))     -- before the load: DllMain reads it
    local winPath = path:gsub("/", "\\")
    local ok, r1, r2, r3 = pcall(package.loadlib, winPath, "*")
    if ok and r1 then
        S.native.loaded = true
        local st = readNativeStatus()
        U.log(TAG, "native filter loaded: installed=%s reason=%s", tostring(st.installed), tostring(st.reason))
        if st.installed ~= "1" then
            U.warn(TAG, "native filter did not patch (%s): falling back to kbsplit", tostring(st.reason))
        end
    else
        S.native.err = tostring(ok and r2 or r1) .. (r3 and (" (" .. tostring(r3) .. ")") or "")
        U.warn(TAG, "package.loadlib(%s) failed: %s", winPath, S.native.err)
    end
    return S.native.loaded
end

---------------------------------------------------------------------------------------------------- players
-- Local players with a PC: { ctrlId, pc, sub (its UGfnRawInputSubsystem), car (VehiclePawn or nil) }.
local function localPlayers()
    local out = {}
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) then
            local sub
            pcall(function() sub = e.pc.RawInputSubsystem end)              -- AGfnPlayerController +0x8d8
            sub = weakGet(sub)   -- the property is a TWeakObjectPtr: unwrap to the UObject (live run 2026-10-07)
            if not U.ok(sub) then
                -- fallback: the LocalPlayer's own subsystem
                pcall(function()
                    sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(e.pc,
                        U.class("/Script/Griffin.GfnRawInputSubsystem"))
                end)
            end
            -- the LocalPlayer's own subsystem too: a car bound to either one is "own" (they should be the same object;
            -- run E showed P1's car reading LocalPlayers[0]'s subsystem while the check said "not bound")
            S.lpSubCache = S.lpSubCache or {}
            local pk = U.key(e.pc)
            local lpSubKey = S.lpSubCache[pk]
            if lpSubKey == nil then
                local lpSub
                pcall(function()
                    lpSub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(e.pc,
                        U.class("/Script/Griffin.GfnRawInputSubsystem"))
                end)
                lpSubKey = addrOf(lpSub)
                if lpSubKey ~= 0 then S.lpSubCache[pk] = lpSubKey end
            end
            local car
            pcall(function()
                local pawn = e.pc.Pawn
                if U.ok(pawn) and U.isVehicle(pawn) then car = pawn end
            end)
            out[#out + 1] = { ctrlId = e.ctrlId, pc = e.pc, sub = U.ok(sub) and sub or nil, car = car,
                              subKey = addrOf(sub), lpSubKey = lpSubKey or 0, index = e.index }
        end
    end
    return out
end

---------------------------------------------------------------------------------------------------- bind
-- Points the car's PlayerInputComponent at its owner's raw subsystem. Returns "own", "bound", "pending", "fail", "n/a".
-- "own": the car's weak pointer resolves to the ADDRESS of its owner's subsystem (PC.RawInputSubsystem, or the
-- LocalPlayer subsystem of that PC). "pending": the native copy was requested less than NATIVE_GRACE_MS ago.
local NATIVE_GRACE_MS = 1500

local function isOwnAddr(p, a)
    return a ~= 0 and (a == (p.subKey or 0) or a == (p.lpSubKey or 0))
end

local function bindCar(p)
    if not p.car or not p.sub then return "n/a" end
    local comp
    pcall(function() comp = p.car.PlayerInputComponent end)
    if not U.ok(comp) then return "n/a" end
    local carKey = U.key(p.car)
    local rec = S.cars[carKey] or {}
    S.cars[carKey] = rec
    local cur = comp.RawInputSubsystem
    local curA = addrOf(cur)
    if isOwnAddr(p, curA) then
        local w = S.native.writes[carKey]
        if w then
            S.native.writes[carKey] = nil
            S.native.seq = S.native.seq + 1
            U.log(TAG, "car %s (ControllerId %d): raw input bound by the native copy -> %s @0x%x (verified by address)",
                nm(p.car), p.ctrlId, nm(p.sub), curA)
            return "bound"
        end
        return "own"
    end
    -- Lua write (UE4SS refuses TWeakObjectPtr writes in this build: tried until it fails once, then never again, so a
    -- FAST loop never prints a traceback per tick)
    local okW = false
    if not S.luaWeakBroken then
        local okP, err = pcall(function() comp.RawInputSubsystem = weakGet(p.sub) end)
        if okP then
            okW = true
        else
            S.luaWeakBroken = true
            U.log(TAG, "Lua cannot write PlayerInputComponent.RawInputSubsystem (%s): the native copy does it from now on",
                tostring(err):match("^[^\n]*") or "?")
        end
    end
    local nowA = addrOf(comp.RawInputSubsystem)
    if okW and isOwnAddr(p, nowA) then
        S.counts.bind = S.counts.bind + 1
        rec.binds = (rec.binds or 0) + 1
        U.log(TAG, "car %s (ControllerId %d): raw input %s -> %s%s", nm(p.car), p.ctrlId, nm(weakGet(cur)), nm(p.sub),
            rec.binds > 1 and string.format(" (re-bound x%d: the game reset it)", rec.binds) or "")
        return "bound"
    end
    -- let the DLL build the weak pointer {ObjectIndex, SerialNumber} of the owner's raw subsystem into
    -- PlayerInputComponent.RawInputSubsystem (@0xc0)
    local now = St.nowMs()
    local w = S.native.writes[carKey]
    if S.native.loaded and not w and U.key(comp) ~= 0 and p.subKey ~= 0 then
        local t = os.time() * 1000 + (S.native.wTag % 1000) + 1
        if t <= S.native.wTag then t = S.native.wTag + 1 end
        S.native.wTag = t
        w = { tag = t, dst = U.key(comp) + 0xc0, obj = p.subKey, atMs = now }
        S.native.writes[carKey] = w
        S.native.seq = S.native.seq + 1
        U.log(TAG, "car %s (ControllerId %d): reads %s @0x%x, own is %s @0x%x: native weak-pointer copy requested (tag %d)",
            nm(p.car), p.ctrlId, nm(weakGet(cur)), curA, nm(p.sub), p.subKey, t)
    end
    if w and now - (w.atMs or 0) < NATIVE_GRACE_MS then return "pending" end
    S.counts.bindFail = S.counts.bindFail + 1
    -- VERIFY(V-INP-01): never seen after the first second of a race; if it is, the addresses tell which side is off
    U.logEvery("inputfix.bindfail" .. carKey, 5000, TAG, "car %s (ControllerId %d): raw input still 0x%x (%s), own "
        .. "pc 0x%x / localplayer 0x%x%s", nm(p.car), p.ctrlId, nowA, nm(weakGet(comp.RawInputSubsystem)),
        p.subKey or 0, p.lpSubKey or 0, w and string.format(" (native copy tag %d not applied)", w.tag) or "")
    return "fail"
end

---------------------------------------------------------------------------------------------------- contexts
-- Desired ActiveMappingContexts of one player's raw subsystem, or nil = leave as is.
-- kbsplit: guests drop keyboard contexts; P1 drops pad contexts when it is the keyboard player (KeyboardIsP1 or
-- InputFixKbSplitP1 = "always"). fill: a guest list with no vehicle pad context gets the pad IMCs seen elsewhere.
-- The vehicle pad IMC a guest gets when its raw subsystem has none: the scheme P1's list used (S.p1PadName,
-- remembered before any kbsplit), else IMC_Vehicle_Default (StaticFindObject when no list ever showed it).
function M.padImcForFill()
    local want = S.p1PadName or "IMC_Vehicle_Default"
    local any
    for _, imc in pairs(S.padImcs) do
        if U.ok(imc) then
            if nm(imc) == want then return imc end
            any = any or imc
        end
    end
    if any then return any end
    local ok, o = pcall(StaticFindObject, "/Game/Griffin/Config/Input/" .. want .. "." .. want)
    if ok and U.ok(o) then imcKind(o); return o end
    return nil
end

local function desiredCtx(p, list, kbsplit)
    local isP1 = (p.ctrlId == 0)
    local p1Rule = opt("InputFixKbSplitP1", "kbp1")
    local dropKb = kbsplit and not isP1
    local dropPad = kbsplit and isP1 and (p1Rule == "always" or (p1Rule == "kbp1" and keyboardIsP1()))
    local out, changed, hasPad, filled = {}, false, false, false
    for _, imc in ipairs(list) do
        local k = imcKind(imc)
        if (dropKb and k == "kb") or (dropPad and k == "pad") then
            changed = true
        else
            out[#out + 1] = imc
            if k == "pad" or k == "mixed" then hasPad = true end
        end
    end
    if not isP1 and not hasPad and opt("InputFixGuestContexts", "fill") == "fill" then
        local pick = M.padImcForFill()
        if pick then out[#out + 1] = pick; changed = true; filled = true end
    end
    if not changed then return nil end
    return out, filled
end

local function applyContexts(players, kbsplit)
    for _, p in ipairs(players) do
        if p.sub then                                                            -- learn pad IMCs first
            for _, imc in ipairs(ctxList(p.sub)) do
                if imcKind(imc) == "pad" and p.ctrlId == 0 and not S.p1PadName then S.p1PadName = nm(imc) end
            end
        end
    end
    for _, p in ipairs(players) do
        if p.sub and p.car then
            local list = ctxList(p.sub)
            local want, filled = desiredCtx(p, list, kbsplit)
            if want and not sameList(want, list) then
                if writeCtx(p.sub, list, want) then
                    if filled then S.counts.ctxFilled = S.counts.ctxFilled + 1 end
                    S.counts.ctxApplied = S.counts.ctxApplied + 1
                    U.logEvery("inputfix.ctx" .. p.ctrlId, 2000, TAG, "ControllerId %d raw contexts {%s} -> {%s}%s",
                        p.ctrlId, ctxNames(list), ctxNames(want), filled and " (filled)" or "")
                end
            end
        end
    end
end

------------------------------------------------------------------------------------------- guest Enhanced Input
-- LIVE FINDING F1 (run G 2026-10-07, state/runs/20261007-1217-session-G/UE4SS-124253.log): a guest's
-- EnhancedInputLocalPlayerSubsystem has NO vehicle mapping context. Guest PlayerInput.EnhancedActionMappings: 98
-- mappings, 0 IA_Veh_* (P1: 126, 28 IA_Veh_*). So every Enhanced Input vehicle action of a guest was dead: the PC's
-- InpActEvt_IA_Veh_* events (pre-flight checks, pause, camera, photo mode), the car's own EI bindings (ChangeBoost,
-- ChangeCamera, throttle toggle) and the ENGINE IGNITE step (FailedIgnite for P2 although ignpad completed its checks).
-- Proven fix (testcmd seq 1791369706 / -721):
--   sub = SubsystemBlueprintLibrary:GetLocalPlayerSubSystemFromPlayerController(guestPC,
--                                                    class /Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem)
--   sub:AddMappingContext(IMC_Vehicle_Default, 1, {})   -- DIRECT method call; CallFunction with the interface
--                                                       -- UFunction fails ("...without both UFunction and calling
--                                                       -- context")
--   -> after the deferred rebuild 19 IA_Veh_* mappings; P2's Start opened WBP_PauseRacing through the game's own path.
-- Here (cfg.InputFixGuestEnhanced = "add", default; "off"): polled from M.tick in race phases, plus the
-- PossessedPawnChanged hook. Every guest PC that possesses a vehicle gets the vehicle PAD IMC P1 uses
-- (IMC_Vehicle_Default or _Alternative, asked from P1's own Enhanced Input subsystem, else P1's raw scheme, else
-- Default; NEVER IMC_Vehicle_Keyboard: keyboard and mouse belong to user 0) at P1's priority (else
-- cfg.InputFixGuestEnhancedPriority). HasMappingContext (out OutFoundPriority) detects a cleared / rebuilt list ->
-- re-added (at most once a second, logged with the count); when HasMappingContext is not callable, the IA_Veh_* count
-- decides. After each add the guest's IA_Veh_* mappings are counted on every poll until they show (the rebuild is
-- deferred; a warning after 3 s). FRONTEND removes what this module added (cfg.InputFixGuestEnhancedRemove, default
-- true). Photo mode: left alone (M.tick backs off).
-- VERIFY(V-INP-08): "P2 (ControllerId 1) Enhanced Input: IMC_Vehicle_Default added (priority ...)" then "P2 Enhanced
--   Input verified: 19 IA_Veh_* ..." before the pre-flight checks; ignpad then logs "P2 check input: watching -> game".
--   If the count stays 0 (warning "applied but PlayerInput lists 0"): InputFixGuestEnhanced = "off" (0.5.1 behaviour).
local EI_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
local IMC_DIR = "/Game/Griffin/Config/Input/"
local PAD_SCHEMES = { "IMC_Vehicle_Default", "IMC_Vehicle_Alternative" }
-- [EI subsystem address] = { sub, pc, pcKey, pnum, ours, imc, imcPath, prio, adds, addAt, state, count, verified }
S.ei = S.ei or {}

local function eiMode()
    return opt("InputFixGuestEnhanced", "add") == "off" and "off" or "add"
end

local function eiSub(pc)
    local sub
    pcall(function() sub = U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, U.class(EI_CLASS)) end)
    return U.ok(sub) and sub or nil
end

local function imcByName(name)
    local ok, o = pcall(StaticFindObject, IMC_DIR .. name .. "." .. name)
    return (ok and U.ok(o)) and o or nil
end

-- HasMappingContext(imc, out int32 OutFoundPriority) -> true|false, priority; nil, nil, err when not callable.
local function eiHas(sub, imc)
    local out = {}
    local ok, r = pcall(function() return sub:HasMappingContext(imc, out) end)
    if not ok then return nil, nil, tostring(r):match("^[^\n]*") end
    if type(r) ~= "boolean" then return nil, nil, "returned " .. type(r) end
    return r, math.tointeger(tonumber(out.OutFoundPriority))
end

---------------------------------------------------------------------------------------------------- P1 vehicle over UI
-- 0.9.0 (run L, 2026-10-07, 3 players): P1's LB (IA_Veh_TriggerAbility, "side fire") and R3 (IA_Veh_ChangeBoost,
-- "blue boost") did nothing while racing; the guests' did not have that problem. IMC_UI maps LB / R3 / A / B / d-pad /
-- Start to UI actions (IA_UI_Tab_Left, IA_UI_HideTooltips, ...), and the game's InputModeManager raises IMC_UI to 500
-- for the FIRST local player only (pause-split.md §3.4) whenever it counts interactive UI as shown, while the vehicle
-- pad IMC sits at 0: those UI mappings win. The analog raw path (steer, throttle, A boost) is not affected. Lowering
-- IMC_UI would not stick (the manager re-applies it on every OnControlMappingsRebuilt). So while P1 RACES in a split
-- race with no pause and no photo mode, P1's vehicle IMCs are put just above IMC_UI; they get their own priority back
-- at once on a pause / photo mode / leaving RACING (FAST loop, 33 ms). The first check of every race logs both
-- priorities (the data, even when nothing needs to change). cfg.InputFixP1VehicleOverUi = true | false.
-- VERIFY(V-INP-09): "P1 racing: IMC_UI 500, vehicle IMC_Vehicle_Default 0" then "P1 vehicle input over the UI context:
--   IMC_Vehicle_Default 0 -> 501"; LB / R3 work for P1; the pause menu still navigates with P1's pad.
local IMC_UI_PATH = "/Game/Griffin/Config/Input/UI/IMC_UI.IMC_UI"
local P1_VEH_IMCS = { "IMC_Vehicle_Default", "IMC_Vehicle_Alternative", "IMC_Vehicle_Keyboard" }
local P1G = { raised = {}, checked = false, nextMs = 0 }

local function imcUi()
    local ok, o = pcall(StaticFindObject, IMC_UI_PATH)
    return (ok and U.ok(o)) and o or nil
end

-- Back to the priorities P1's vehicle IMCs had before we raised them.
function M.p1UiRelease(why)
    if next(P1G.raised) == nil then return end
    local p1 = U.p1()
    local sub = U.ok(p1) and eiSub(p1) or nil
    local parts = {}
    for name, r in pairs(P1G.raised) do
        local ok = sub and U.ok(r.imc) and pcall(function() sub:AddMappingContext(r.imc, r.orig, {}) end)
        parts[#parts + 1] = string.format("%s %d -> %d%s", name, r.prio, r.orig, ok and "" or " (failed)")
    end
    P1G.raised = {}
    U.log(TAG, "P1 vehicle input back to its own priority (%s): %s (V-INP-09)", tostring(why), table.concat(parts, ", "))
end

-- FAST loop (main.lua), every phase: acts in RACING split races only, releases everywhere else.
function M.p1UiGuard()
    if opt("InputFixP1VehicleOverUi", true) == false then return end
    local racing = St.phase == "RACING"
    if racing then
        local n = 0
        pcall(function() n = #U.localPlayers() end)
        racing = n >= 2
    end
    local paused = false
    if racing then
        local okP, v = pcall(U.csmPaused)
        paused = okP and v == true
    end
    local photo = racing and photoActive() or false
    if not racing or paused or photo then
        if next(P1G.raised) ~= nil then
            M.p1UiRelease(paused and "pause" or (photo and "photo mode" or ("phase " .. tostring(St.phase))))
        end
        if not racing then P1G.checked = false end
        return
    end
    local now = St.nowMs()
    if now < P1G.nextMs then return end
    P1G.nextMs = now + 250
    local p1 = U.p1()
    if not U.ok(p1) then return end
    local sub = eiSub(p1)
    local ui = imcUi()
    if not (sub and ui) then return end
    local hasUi, uiPrio = eiHas(sub, ui)
    if hasUi == nil then return end
    uiPrio = hasUi and (uiPrio or 0) or nil
    local seen = {}
    for _, name in ipairs(P1_VEH_IMCS) do
        local imc = imcByName(name)
        local has, prio = nil, nil
        if imc then has, prio = eiHas(sub, imc) end
        if has then
            prio = prio or 0
            seen[#seen + 1] = string.format("%s %d", name, prio)
            if uiPrio and prio <= uiPrio then
                local r = P1G.raised[name]
                local want = uiPrio + 1
                local ok = pcall(function() sub:AddMappingContext(imc, want, {}) end)
                P1G.raised[name] = { imc = imc, orig = r and r.orig or prio, prio = want }
                U.log(TAG, "P1 vehicle input over the UI context: %s %d -> %d (IMC_UI at %d)%s (V-INP-09)", name, prio,
                    want, uiPrio, ok and "" or " - AddMappingContext FAILED")
            end
        end
    end
    if not P1G.checked then
        P1G.checked = true
        U.log(TAG, "P1 racing: IMC_UI %s, vehicle %s (V-INP-09)", uiPrio and tostring(uiPrio) or "absent",
            #seen > 0 and table.concat(seen, ", ") or "none")
    end
end

--- IA_Veh_* entries of a PC's UEnhancedPlayerInput.EnhancedActionMappings (FEnhancedActionKeyMapping: Action object,
--- Key; no soft field) -> count (nil = unreadable), total, "Boost,Brake,..."
function M.countVehMappings(pc)
    local n, total, set = 0, 0, {}
    local ok = pcall(function()
        pc.PlayerInput.EnhancedActionMappings:ForEach(function(_, el)
            total = total + 1
            if total > 800 then return true end
            local a = nm(el:get().Action)
            if a:sub(1, 7) == "IA_Veh_" then n = n + 1; set[a:sub(8)] = true end
        end)
    end)
    if not ok then return nil, total, "unreadable" end
    local t = {}
    for a in pairs(set) do t[#t + 1] = a end
    table.sort(t)
    return n, total, table.concat(t, ",")
end

-- The vehicle pad IMC + priority P1 uses (cached 5 s): P1's Enhanced Input first, then its raw scheme.
local function guestImc(players)
    local now = St.nowMs()
    local c = S.eiP1
    if c and U.ok(c.imc) and now - c.atMs < 5000 then return c.imc, c.prio, c.src end
    local p1
    for _, p in ipairs(players) do if (p.index or p.ctrlId + 1) == 1 then p1 = p end end
    local imc, prio, src
    local sub = p1 and eiSub(p1.pc)
    if sub then
        for _, name in ipairs(PAD_SCHEMES) do
            local o = imcByName(name)
            local has, pr = nil, nil
            if o then has, pr = eiHas(sub, o) end
            if has then imc, prio, src = o, pr, "P1 Enhanced Input"; break end
        end
    end
    if not imc and p1 and p1.sub and not S.p1PadName then          -- P1's raw scheme (before any kbsplit edit)
        for _, o in ipairs(ctxList(p1.sub)) do
            if imcKind(o) == "pad" then S.p1PadName = nm(o); break end
        end
    end
    if not imc then
        local f = M.padImcForFill()
        if f and imcKind(f) == "pad" then imc, src = f, S.p1PadName and "P1 raw scheme" or "default" end
    end
    if not imc then return nil end
    if not prio then
        prio, src = math.tointeger(opt("InputFixGuestEnhancedPriority", 1)) or 1, src .. ", cfg priority"
    end
    S.eiP1 = { imc = imc, prio = prio, src = src, atMs = now }
    return imc, prio, src
end

local function eiVerify(rec, now)
    local n, total, names = M.countVehMappings(rec.pc)
    local age = math.floor(now - (rec.addAt or now))
    if n and n > 0 then
        rec.verified, rec.state, rec.count = now, "ok", n
        U.log(TAG, "P%d Enhanced Input verified: %d IA_Veh_* of %d mappings %d ms after the add (%s)", rec.pnum, n,
            total, age, names)
    elseif age >= 3000 then
        rec.verified, rec.state, rec.count = now, "unverified", n or 0
        U.warn(TAG, "P%d Enhanced Input: %s applied but PlayerInput lists %s IA_Veh_* of %d mappings %d ms later "
            .. "(V-INP-08; InputFixGuestEnhanced = \"off\" restores the 0.5.1 behaviour)", rec.pnum, nm(rec.imc),
            tostring(n), total, age)
    end
end

local function eiGuest(p, imc, prio, src, now)
    local sub = eiSub(p.pc)
    local pnum = p.index or (p.ctrlId + 1)
    if not sub then
        U.logEvery("inputfix.ei.nosub" .. pnum, 10000, TAG, "P%d: no EnhancedInputLocalPlayerSubsystem", pnum)
        return
    end
    local k = U.key(sub)
    local rec = S.ei[k]
    if not rec then rec = { adds = 0, state = "new" }; S.ei[k] = rec end
    rec.sub, rec.pc, rec.pcKey, rec.pnum, rec.ctrlId = sub, p.pc, U.key(p.pc), pnum, p.ctrlId
    local has, _, err = eiHas(sub, imc)
    if has == nil then
        if not S.eiHasBroken then
            S.eiHasBroken = true
            U.log(TAG, "HasMappingContext not callable (%s): the IA_Veh_* count decides", tostring(err))
        end
        if now - (rec.countAt or -1e12) < 1000 then return end      -- count at most once a second
        rec.countAt = now
        has = (M.countVehMappings(p.pc) or 0) > 0
        if not has and rec.addAt and now - rec.addAt < 1500 then return end   -- deferred rebuild still pending
    end
    if has then
        if rec.state == "new" then
            rec.state = "game"
            U.log(TAG, "P%d Enhanced Input already maps %s (the game's own): left alone", pnum, nm(imc))
        end
        if rec.ours and not rec.verified then eiVerify(rec, now) end
        return
    end
    if rec.addAt and now - rec.addAt < 1000 then return end           -- one add per second at most
    local ok, e2 = pcall(function() sub:AddMappingContext(imc, prio, {}) end)   -- VERIFY(V-INP-08)
    rec.adds, rec.addAt, rec.verified = rec.adds + 1, now, nil
    rec.ours, rec.imc, rec.imcPath, rec.prio = true, imc, U.pathOf(imc), prio
    if ok then
        rec.state = "pending"
        -- integration 0.6.0: a HasMappingContext that keeps reading false would re-add every second: from the 6th add on
        -- the line is rate-limited (the re-add itself is harmless: same IMC, same priority)
        local logf = rec.adds > 5 and function(...) U.logEvery("inputfix.ei.readd" .. pnum, 15000, ...) end or U.log
        logf(TAG, "P%d (ControllerId %d) Enhanced Input: %s added (priority %d, from %s)%s", pnum, p.ctrlId, nm(imc),
            prio, tostring(src), rec.adds > 1
                and string.format(" - re-added x%d: the game cleared/rebuilt its contexts", rec.adds - 1) or "")
    else
        rec.state, rec.err = "fail", tostring(e2):match("^[^\n]*")
        U.logEvery("inputfix.ei.fail" .. pnum, 5000, TAG, "P%d Enhanced Input: AddMappingContext(%s) failed: %s", pnum,
            nm(imc), rec.err)
    end
end

-- Race phases (game thread, M.tick): every guest that possesses a vehicle.
local function eiGuests(players)
    if eiMode() == "off" then return end
    local now = St.nowMs()
    local imc, prio, src
    for _, p in ipairs(players) do
        if (p.index or p.ctrlId + 1) > 1 and p.car and U.ok(p.pc) then
            if not imc then
                imc, prio, src = guestImc(players)
                if not imc then
                    U.logEvery("inputfix.ei.noimc", 10000, TAG, "guest Enhanced Input: no vehicle pad IMC found")
                    return
                end
            end
            eiGuest(p, imc, prio, src, now)
        end
    end
end

--- ignpad: a guest's Enhanced Input vehicle context -> state, IA_Veh_* count. state: "ok" (added + verified) | "game"
--- (the game's own) | "pending" (added, rebuild not verified yet) | "unverified" | "fail" | "off" | nil (not handled).
function M.guestVehicleInput(pc)
    if mode() == "off" or eiMode() == "off" then return "off", nil end
    local pk = U.key(pc)
    if pk == 0 then return nil end
    for _, rec in pairs(S.ei) do
        if rec.pcKey == pk then return rec.state, rec.count end
    end
    return nil
end

--- FRONTEND (game thread): remove the vehicle IMC this module added to guests (their menus never see IA_Veh_*).
function M.eiRestore()
    if opt("InputFixGuestEnhancedRemove", true) == false then S.ei = {}; return end
    local live = {}
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) then
            local s = eiSub(e.pc)
            if s then live[U.key(s)] = s end
        end
    end
    for k, rec in pairs(S.ei) do
        if rec.ours then
            U.try(TAG, function()
                local sub = live[k]
                local imc = U.ok(rec.imc) and rec.imc or (rec.imcPath and select(2, pcall(StaticFindObject, rec.imcPath)))
                if not sub or not U.ok(imc) then return end
                sub:RemoveMappingContext(imc, {})
                U.log(TAG, "P%s Enhanced Input: %s removed (front end)", tostring(rec.pnum), nm(imc))
            end)
        end
    end
    S.ei, S.eiP1 = {}, nil
end

---------------------------------------------------------------------------------------------------- tick
-- Pad players: KeyboardIsP1 -> every guest; else every local player (P1 also has pad 1).
local function padPlayerCount(players)
    local n = 0
    for _, p in ipairs(players) do
        if p.car and (p.ctrlId ~= 0 or not keyboardIsP1()) then n = n + 1 end
    end
    return n
end

local lastTickMs = -1e12

-- Binds every local car; S.allBound = every car "own"/"bound" (nil when no local car exists yet: the filter has
-- nothing to protect then and stays as the scope says). Returns true when allBound changed.
bindAll = function(players)
    local all, cars, bad = true, 0, nil
    local desc = {}
    for _, p in ipairs(players) do
        if p.car then
            cars = cars + 1
            local r = bindCar(p)
            local rec = S.cars[U.key(p.car)] or {}
            S.cars[U.key(p.car)] = rec
            rec.ctrlId, rec.last = p.ctrlId, r
            if r ~= "own" and r ~= "bound" then
                all = false
                if r ~= "pending" then bad = bad or p end
            end
            desc[#desc + 1] = string.format("ctrl %d %s", p.ctrlId, r)
        end
    end
    local new = (cars > 0) and all or nil
    if bad then
        U.logEvery("inputfix.unbound", 5000, TAG, "car %s (ControllerId %d) is not bound to its own raw input: native "
            .. "filter held off and contexts left alone (V-INP-01; InputFixMode = \"off\" if this persists)",
            nm(bad.car), bad.ctrlId)
    end
    local changed = (new ~= S.allBound)
    if changed and (new == true or S.allBound == true) then
        -- VERIFY(V-INP-01): "every local car reads its own raw input" within ~1 s of the cars spawning
        U.log(TAG, "%s (%s)", new == true and "every local car reads its own raw input: native filter + contexts on"
            or "a local car lost its own raw input: native filter held off", table.concat(desc, ", "))
    end
    S.allBound = new
    return changed
end

--- FAST loop (main.lua, race phases): re-check the binds every ~33 ms so a car the game re-points (respawn/reset)
--- is fixed at once; the cfg is rewritten only when the all-bound state flips (writeNativeCfg skips equal text).
-- Photo-mode edge (both loops): S.photo gates the native cfg and the context edits. VERIFY(V-INP-07): "photo mode
-- open: native filter off" / "photo mode closed" in the log around a photo-mode visit; the pads drive the photo
-- cameras (if not: the game reads photo input elsewhere, see input-isolation.md §photo mode).
local function photoEdge(players)
    local on = photoActive()
    if on == (S.photo == true) then return false end
    S.photo = on
    if on then
        local d = {}
        local pm = U.worldSubsystem("/Script/PhotoMode.PhotoModeManager")
        for _, p in ipairs(players or {}) do
            local pn, hud = "?", "?"
            pcall(function() pn = nm(p.pc.Pawn and p.pc.Pawn:GetClass()) end)
            -- UPhotoModeManager:GetHudWidgetForPlayer(Object pc) -> Object (reflect-func-all 2026-10-07)
            pcall(function()
                local w = pm:GetHudWidgetForPlayer(p.pc)
                hud = U.ok(w) and string.format("%s(inViewport=%s)", nm(w), tostring(w:IsInViewport())) or "none"
            end)
            d[#d + 1] = string.format("ctrl %d pawn %s hud %s", p.ctrlId, pn, hud)
        end
        U.log(TAG, "photo mode open: native filter off, raw contexts left alone (%s)", table.concat(d, ", "))
    else
        U.log(TAG, "photo mode closed: binds and filter resume")
    end
    if S.native.loaded then writeNativeCfg(buildNativeCfg(players or localPlayers())) end
    return true
end

function M.bindPoll()
    if mode() == "off" or not isRacePhase() then return end
    if photoActive() or S.photo then
        if photoEdge(localPlayers()) or S.photo then return end
    end
    local players = localPlayers()
    if #players < 2 then return end
    if bindAll(players) and S.native.loaded then writeNativeCfg(buildNativeCfg(players)) end
end

--- Poll entry (own sched loop, or main's MAIN loop). Front end: only keeps the DLL's cfg current. Race phases with
--- 2+ local players: bind every human car, then kbsplit/fill the raw mapping contexts. Idempotent and cheap.
function M.tick()
    local m = mode()
    if m == "off" then return end
    local now = St.nowMs()
    if now - lastTickMs < 40 then return end      -- main + own loop: run once per window
    lastTickMs = now
    local players = localPlayers()
    local race = isRacePhase() and #players >= 2
    if race then photoEdge(players) end
    if race and S.photo then
        if S.native.loaded then writeNativeCfg(buildNativeCfg(players)) end
        return
    end
    if race then bindAll(players) else S.allBound = nil end
    if race then U.tryEvery("inputfix.ei", 5000, TAG, eiGuests, players) end   -- F1: guests' vehicle IMC (V-INP-08)
    if nativeWanted() then
        if not S.native.tried and #players > 1 then loadNative(players) end
        if S.native.loaded then writeNativeCfg(buildNativeCfg(players)) end
    end
    if not race then return end
    if S.allBound == false then return end        -- kbsplit/fill only help a bound car (see bindAll)
    local kbsplit = (m == "kbsplit") or (m == "auto" and not nativeActive())
    applyContexts(players, kbsplit)
    if kbsplit and padPlayerCount(players) >= 2 and not S.warned.pads then
        S.warned.pads = true
        U.warn(TAG, "native input filter not active (%s): players on PADS still share steering/throttle; "
            .. "keyboard vs pad is isolated. Install native/%s for full isolation.",
            tostring(S.native.err or S.native.status.reason or "mode " .. m), DLL_NAME)
    end
end

local function soon()
    sched.after("inputfix.soon", 50, function() U.try(TAG, M.tick) end)
end

---------------------------------------------------------------------------------------------------- diag
--- Lines describing the current binding per local player and the native filter (diag.lua can print them).
function M.diagLines()
    local L = {}
    local function add(f, ...) L[#L + 1] = string.format(f, ...) end
    local st = S.native.status or {}
    add("inputfix: mode=%s native{tried=%s loaded=%s installed=%s reason=%s err=%s} kbsplit=%s KeyboardIsP1=%s "
        .. "offset=%s binds=%d bindFail=%d ctxApplied=%d ctxFilled=%d",
        mode(), tostring(S.native.tried), tostring(S.native.loaded), tostring(st.installed), tostring(st.reason),
        tostring(S.native.err), tostring(mode() == "kbsplit" or (mode() == "auto" and not nativeActive())),
        tostring(keyboardIsP1()), tostring(padOffset()), S.counts.bind, S.counts.bindFail, S.counts.ctxApplied,
        S.counts.ctxFilled)
    local players = localPlayers()
    local bySub = {}
    for _, p in ipairs(players) do if p.sub then bySub[U.key(p.sub)] = p.ctrlId end end
    for _, p in ipairs(players) do
        local epi, epiOwner = "nil", "?"
        pcall(function()
            local e = p.sub.EnhancedPlayerInput
            epi = nm(e)
            epiOwner = (addrOf(e:GetOuter()) == U.key(p.pc)) and "own pc" or ("outer " .. nm(e:GetOuter()))
        end)
        local carRaw, verdict = "n/a", "no car"
        if p.car then
            pcall(function()
                local r = weakGet(p.car.PlayerInputComponent.RawInputSubsystem)
                local a = addrOf(r)
                local owner = bySub[a]
                carRaw = string.format("%s@0x%x(ctrl %s)", nm(r), a, tostring(owner))
                verdict = isOwnAddr(p, a) and "bound=own" or "bound=WRONG"
            end)
        end
        add("  ctrl=%d pc=%s raw=%s ctx={%s} epi=%s(%s) car=%s carRaw=%s %s", p.ctrlId, nm(p.pc), nm(p.sub),
            p.sub and ctxNames(ctxList(p.sub)) or "", epi, epiOwner, nm(p.car), carRaw, verdict)
        local vn, vt = M.countVehMappings(p.pc)
        local est, ecount = M.guestVehicleInput(p.pc)
        add("    enhanced: IA_Veh_*=%s of %s mappings, guest vehicle IMC state=%s count=%s", tostring(vn), tostring(vt),
            tostring(est), tostring(ecount))
    end
    if S.native.loaded then
        add("  native: enabled=%s offset=%s seq=%s unknown_passed=%s", tostring(st.enabled), tostring(st.offset),
            tostring(st.seq), tostring(st.unknown_passed))
        for _, o in ipairs(st.owners or {}) do add("    %s", o) end
    end
    return L
end

--- Logs M.diagLines(), then asks the DLL for fresh counters and logs its status again ~0.7 s later.
function M.dump()
    for _, l in ipairs(M.diagLines()) do U.log(TAG, "%s", l) end
    if S.native.loaded then
        S.native.seq = S.native.seq + 1
        writeNativeCfg(buildNativeCfg(localPlayers()))
        sched.after("inputfix.status", 700, function()
            local st = readNativeStatus()
            U.log(TAG, "native status seq=%s: installed=%s enabled=%s offset=%s unknown_passed=%s",
                tostring(st.seq), tostring(st.installed), tostring(st.enabled), tostring(st.offset),
                tostring(st.unknown_passed))
            for _, o in ipairs(st.owners or {}) do U.log(TAG, "  %s", o) end
        end)
    end
end

---------------------------------------------------------------------------------------------------- init
local inited = false

function M.init()
    if inited then return end
    inited = true
    if mode() == "off" then
        U.log(TAG, "InputFixMode=off: nothing done")
        return
    end
    St.on("phase", TAG, function(new, old)
        if new == "LOADING" or new == "FRONTEND" then
            S.cars, S.lpSubCache, S.photo = {}, {}, nil
            S.native.writes = {}     -- weak-pointer copies of the previous race's cars (addresses die with the world)
        end
        if new == "FRONTEND" then
            S.p1PadName = nil
            M.restoreContexts()
            M.eiRestore()
        end
        S.eiP1 = nil                                -- P1's scheme/priority is re-read in the next race
        lastTickMs = -1e12
        M.tick()                                    -- DLL cfg: enabled follows the phase at once
    end)
    St.on("settings", TAG, function(key)
        if key == "KeyboardIsP1" then S.warned.pads = nil; lastTickMs = -1e12; soon() end
    end)
    -- native hooks fire in this build; the poll below is the required path, these only make the first bind faster
    U.hook("/Script/Griffin.GfnPlayerController:PossessedPawnChanged", { post = function() soon() end }, TAG)
    U.hook("/Script/Griffin.VehiclePawn:Multi_ReceiveControllerAssigned", { post = function() soon() end }, TAG)
    local ms = opt("InputFixOwnLoopMs", 250)
    if ms > 0 then sched.every("inputfix", ms, function() U.tryEvery("inputfix.tick", 5000, TAG, M.tick) end) end
    local every = opt("InputFixDiagEveryMs", 0)
    if every > 0 then
        sched.every("inputfix.diag", every, function()
            if isRacePhase() then U.try(TAG, M.dump) end
        end)
    end
    U.log(TAG, "init: mode=%s scope=%s guestContexts=%s kbSplitP1=%s guestEnhanced=%s ownLoop=%d ms", mode(),
        opt("InputFixNativeScope", "race"), opt("InputFixGuestContexts", "fill"), opt("InputFixKbSplitP1", "kbp1"),
        eiMode(), ms)
end

return M
