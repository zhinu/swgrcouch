-- ignpad.lua (Track B; REWRITTEN 2026-10-07 after live run F, 0.5.1): each local player's OWN pad drives its own
-- pre-flight checks, and pad players see pad prompts. Driven by ignition.lua (MAIN: begin/sync/stop) and
-- ignition.fastTick (FAST poll through present.fastTick).
--
-- NO SOFT POINTERS (run F: two UE4SS crashes, AV in memcpy 0xba04 bytes, from soft-object marshalling: the
-- PreFlightChecksByAction map read + GetObjectID, and the TestPreflightCheckInput hook). This file never hooks, reads,
-- writes or passes a TSoftObjectPtr, a soft-keyed map or a soft param. What it calls instead (static analysis):
--   * BP_GfnPlayerController_C binds 9 Enhanced Input action events (InpActEvt_IA_Veh_*, list in EVENT_FN). Each one
--     copies its params into the ubergraph and runs
--       this."Pre Flight Check Component"->TestPreflightCheckInput(Conv_ObjectToSoftObjectReference(SourceAction))
--     (work/exports/present/BP_GfnPlayerController.disasm.txt, ubergraph 29..2983). Params (JMAP): ActionValue
--     (InputActionValue, 0x20 bytes, NO reflected fields: passed as {} = zeros, the graph only feeds it to an unused
--     Conv_InputActionValueToBool), ElapsedTime/TriggeredTime (float), SourceAction (UInputAction*, a plain object).
--     So the mod calls the guest PC's OWN event with the IA asset object: the soft reference is built natively by the
--     VM, exactly as for a real press. "Pre Flight Check Component" is cached by the PC's SetupIgnitionBindings from
--     its own car's PlayerState (ubergraph 2101..2385): the guest's own component.
--   * Native TestPreflightCheckInput (0x1470c73e8): no-op unless bAreChecksUnderway; idle (+0x188 == -1): looks the
--     action up in the map, starts that check (OnPreflightCheckStart); active: compares with InputActions[index]
--     (FSoftObjectPath compare) -> InputCorrect / Success, or Failed + reset. One call per press = a "Started" event.
--   * Why a guest needs this (runs E/F): a guest's IA_Veh_* events never fired (pause.lua had to pause P2 from its
--     poll; session E: P2's screen ignored P2's pad). The probe below logs the guest PlayerInput's
--     EnhancedActionMappings for the check actions: "mapped=0" = the game path cannot fire for that player.
-- Verdict per player ("game" = the game's own input path delivers, the mod only watches | "inject" = the mod calls the
-- PC's event on each of the player's presses | nil = watching):
--   * The detector is the player's own ignition screen (WBP_IgnitionScreen_C, bound to the player's component by
--     "Setup Preflight Checks"): CurrentPreFlightCheckList (set on Start, None on Success/Failed) and SuccessCount
--     (+1 per success) - plain properties. A change that the mod did not cause = the game path works -> "game".
--   * Start (integration 0.5.1): "inject" for a GUEST whose PlayerInput maps none of the check actions while P1's
--     does, for IgnitionPadAssist = "always", and for a guest without a detector; "game" for P1 without a detector and
--     for IgnitionPadAssist = "off"; else watching (P1 always starts watching).
--   * Watching: cfg.IgnitionSilentPresses (guests, default 1) / IgnitionSilentPressesP1 (default 3, on 2+ different
--     actions) presses of a check's FIRST action while no check is active, with no screen reaction within
--     IgnitionPadAssistWindowMs -> "inject" (the last one is injected). Presses during an active check never count (a
--     correct mid-sequence input changes nothing visible).
--   * Safety: a screen change the mod did not cause while "inject" -> back to "game" (warning: double input).
-- 0.6.0 (live finding F1, run G): the guests' IA events were dead because their Enhanced Input subsystem had no
-- vehicle mapping context; inputfix.lua now adds P1's vehicle pad IMC to every guest (V-INP-08). So a guest whose
-- PlayerInput maps check actions, or whose inputfix context is "ok"/"game"/"pending", starts WATCHED like P1 (its own
-- path is preferred; injection stays the fallback after cfg.IgnitionSilentPresses silent check starts). Such a guest's
-- replay waits cfg.IgnitionInjectDelayMs (120) so its own screen reaction is seen first (-> "game", no double input).
-- The mappings are re-probed every cfg.IgnitionMapReprobeMs (1000) until the checks start, and while a guest is
-- injected only because it mapped nothing (it goes back to watching once it maps them).
-- Prompts: cfg.IgnitionPadPrompts = "pads" sets a pad player's CommonInput type to Gamepad; cfg.IgnitionFixedKeys
-- gives the players' input-action widgets (FuseInputActionWidget.InputAction is a plain ObjectProperty) the pad key.
-- VERIFY(V-PRE-06) (0.6.0): "[ignpad] P2 input probe: ... (N total, >0 check ...) eiVehicleCtx=ok ...
--   verdict=watching",
--   then "P2 check input: watching -> game (its screen reacted ...)" on P2's first check press; summary "injected=0".
--   Fallback seen when the context did not help: "silent 1/1" -> "watching -> inject" and "P2 IA_Veh_... -> PC event,
--   inject #1 (N ms after the press)" (a formatted line: F4c fixed); summary "injected=n errors=0".
-- VERIFY(V-PRE-09): P1 "verdict=game" and "P1 check input: watching -> game (its screen reacted ...)" on P1's first
--   D-pad press (P1's own path works, nothing doubled). Fallbacks: IgnitionPadAssist "off" | IgnitionMode
--   "p1game_guestauto".

local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "ignpad"
local PC_BP = "/Game/Griffin/Gameplay/Player/BP_GfnPlayerController.BP_GfnPlayerController_C"
local IA_DIR = "/Game/Griffin/Config/Input/"
local CIS_CLASS = "/Script/CommonInput.CommonInputSubsystem"
local FUSE_IA = "/Script/Griffin.FuseInputActionWidget"
local GAMEPAD = 1   -- ECommonInputType::Gamepad (MouseAndKeyboard = 0)
local OWN_MS = 300  -- a screen change this soon after the mod's own call is the mod's

-- BP_GfnPlayerController_C action events that call TestPreflightCheckInput (export names, disasm + JMAP).
local EVENT_FN = {
    IA_Veh_TriggerAbilitySlot1 = "InpActEvt_IA_Veh_TriggerAbilitySlot1_K2Node_EnhancedInputActionEvent_6",
    IA_Veh_TriggerAbilitySlot2 = "InpActEvt_IA_Veh_TriggerAbilitySlot2_K2Node_EnhancedInputActionEvent_8",
    IA_Veh_TriggerAbilitySlot3 = "InpActEvt_IA_Veh_TriggerAbilitySlot3_K2Node_EnhancedInputActionEvent_7",
    IA_Veh_TriggerAbilitySlot4 = "InpActEvt_IA_Veh_TriggerAbilitySlot4_K2Node_EnhancedInputActionEvent_3",
    IA_Veh_Boost = "InpActEvt_IA_Veh_Boost_K2Node_EnhancedInputActionEvent_5",
    IA_Veh_CriticalMalfunction = "InpActEvt_IA_Veh_CriticalMalfunction_K2Node_EnhancedInputActionEvent_0",
    IA_Veh_ImprovedSteering = "InpActEvt_IA_Veh_ImprovedSteering_K2Node_EnhancedInputActionEvent_4",
    IA_Veh_TopFaceButton = "InpActEvt_IA_Veh_TopFaceButton_K2Node_EnhancedInputActionEvent_2",
    IA_Veh_TriggerAbility = "InpActEvt_IA_Veh_TriggerAbility_K2Node_EnhancedInputActionEvent_1",
}
M.EVENT_FN = EVENT_FN

-- Decoded IMC_Vehicle_Default / _Alternative / _Keyboard (work/decoded-ignition/.../Config/Input/*.json).
local PAD_DEFAULT = {
    IA_Veh_TriggerAbilitySlot1 = { "Gamepad_DPad_Up" }, IA_Veh_TriggerAbilitySlot2 = { "Gamepad_DPad_Left" },
    IA_Veh_TriggerAbilitySlot3 = { "Gamepad_DPad_Down" }, IA_Veh_TriggerAbilitySlot4 = { "Gamepad_DPad_Right" },
    IA_Veh_Boost = { "Gamepad_FaceButton_Bottom" }, IA_Veh_CriticalMalfunction = { "Gamepad_FaceButton_Right" },
    IA_Veh_ImprovedSteering = { "Gamepad_FaceButton_Left" }, IA_Veh_TopFaceButton = { "Gamepad_FaceButton_Top" },
    IA_Veh_TriggerAbility = { "Gamepad_LeftShoulder" }, IA_Veh_Throttle = { "Gamepad_RightTriggerAxis" },
}
local PAD_ALT = {
    IA_Veh_TriggerAbilitySlot1 = { "Gamepad_DPad_Up" }, IA_Veh_TriggerAbilitySlot2 = { "Gamepad_DPad_Left" },
    IA_Veh_TriggerAbilitySlot3 = { "Gamepad_DPad_Down" }, IA_Veh_TriggerAbilitySlot4 = { "Gamepad_DPad_Right" },
    IA_Veh_Boost = { "Gamepad_RightTriggerAxis" }, IA_Veh_CriticalMalfunction = { "Gamepad_FaceButton_Top" },
    IA_Veh_ImprovedSteering = { "Gamepad_FaceButton_Left" }, IA_Veh_TopFaceButton = { "Gamepad_LeftTriggerAxis" },
    IA_Veh_TriggerAbility = { "Gamepad_LeftShoulder" }, IA_Veh_Throttle = { "Gamepad_FaceButton_Bottom" },
}
local KB = {   -- P1 only (keyboard and mouse belong to user 0); mouse buttons are not polled
    IA_Veh_TriggerAbilitySlot1 = { "Up", "One" }, IA_Veh_TriggerAbilitySlot2 = { "Left", "Two" },
    IA_Veh_TriggerAbilitySlot3 = { "Down", "Three" }, IA_Veh_TriggerAbilitySlot4 = { "Right", "Four" },
    IA_Veh_Boost = { "LeftShift" }, IA_Veh_CriticalMalfunction = { "R" }, IA_Veh_ImprovedSteering = { "SpaceBar" },
    IA_Veh_TopFaceButton = { "W" }, IA_Veh_TriggerAbility = { "E", "Q" },
}
-- First action of every decoded check sequence (BP_Ability_*): the "is this a check start" fallback.
local DEFAULT_FIRST = { IA_Veh_TriggerAbilitySlot1 = true, IA_Veh_TriggerAbilitySlot2 = true,
                        IA_Veh_TriggerAbilitySlot3 = true, IA_Veh_TriggerAbilitySlot4 = true, IA_Veh_Boost = true }
-- IsInputKeyDown on an analog trigger: poll its digital twin
local DIGITAL = { Gamepad_RightTriggerAxis = "Gamepad_RightTrigger", Gamepad_LeftTriggerAxis = "Gamepad_LeftTrigger" }

local function S()
    St.ignpad = St.ignpad or { active = false, players = {}, ia = {} }
    return St.ignpad
end

local function opt(k, d)
    local v = cfg[k]
    if v == nil then return d end
    return v
end

local function assistMode()
    local m = opt("IgnitionPadAssist", "auto")
    if m == "auto" or m == "always" or m == "off" then return m end
    return "auto"
end

local function objName(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    if ok and type(s) == "string" then return s end
    return "?"
end

local function short(ia) return (tostring(ia):gsub("^IA_Veh_", "")) end
local function hex(k) return string.format("0x%x", tonumber(k) or 0) end

---------------------------------------------------------------------------------------------------- lookups
-- The IA asset object (a plain UObject: the SourceAction param of the PC's event).
local function iaObject(s, name)
    local o = s.ia[name]
    if U.ok(o) then return o end
    local ok, f = pcall(StaticFindObject, IA_DIR .. name .. "." .. name)
    if ok and U.ok(f) then
        s.ia[name] = f
        return f
    end
    return nil
end

-- How many of the PC events exist in the loaded BP class (once per ignition).
local function eventFnsFound()
    local n, missing = 0, {}
    for ia, fn in pairs(EVENT_FN) do
        local ok, f = pcall(StaticFindObject, PC_BP .. ":" .. fn)
        if ok and U.ok(f) then n = n + 1 else missing[#missing + 1] = short(ia) end
    end
    table.sort(missing)
    return n, missing
end

-- Names of the player's raw-input mapping contexts (object array; the ignition probe reads the same list).
local function rawImcNames(pc)
    local out = {}
    pcall(function()
        pc.RawInputSubsystem.ActiveMappingContexts:ForEach(function(_, el)
            local imc = el:get()
            if U.ok(imc) then out[#out + 1] = objName(imc) end
        end)
    end)
    return out
end

-- The player's Enhanced Input mappings for the check actions (UEnhancedPlayerInput.EnhancedActionMappings @0x628,
-- TArray<FEnhancedActionKeyMapping>: Triggers, Modifiers, Action, Key, ... - no soft field). Returns
-- ok, total, hits, "Slot1=Gamepad_DPad_Up ..." (cfg.IgnitionMapProbe = false skips it: ok = false).
local function enhancedMappings(pc)
    if opt("IgnitionMapProbe", true) == false then return false, 0, 0, "probe off" end
    local total, hits, parts = 0, 0, {}
    local ok, err = pcall(function()
        local arr = pc.PlayerInput.EnhancedActionMappings
        arr:ForEach(function(_, el)
            total = total + 1
            if total > 600 then return true end
            local m = el:get()
            local a = objName(m.Action)
            if EVENT_FN[a] then
                hits = hits + 1
                local kn = "?"
                pcall(function() kn = m.Key.KeyName:ToString() end)
                if #parts < 24 then parts[#parts + 1] = short(a) .. "=" .. kn end
            end
        end)
    end)
    if not ok then return false, total, hits, tostring(err) end
    table.sort(parts)
    return true, total, hits, table.concat(parts, " ")
end

-- Snapshot of the player's own ignition screen: { w = screen key, cur = CurrentPreFlightCheckList key (0 = none),
-- succ = SuccessCount }; nil without a readable screen.
local function snap(e)
    local w = e.screen
    if not U.ok(w) then return nil end
    local cur, succ = 0, -1
    local ok = pcall(function()
        cur = U.key(w.CurrentPreFlightCheckList)
        succ = tonumber(w.SuccessCount) or -1
    end)
    if not ok or succ < 0 then return nil end
    return { w = U.key(w), cur = cur, succ = succ }
end

local function sameSnap(a, b) return a.w == b.w and a.cur == b.cur and a.succ == b.succ end

-- First action of every check list on the player's screen (WBP_Hud_Preflight_List.PreflightActionWidgets[1]
-- -> WBP_Input_Action.InputAction: objects only): { [ia name] = { list key, ... } }. nil when none is readable.
local function firstActions(screen)
    local out, n = {}, 0
    for _, list in ipairs(U.arrayToTable(screen.PreFlightCheckLists)) do
        if U.ok(list) then
            local h = U.arrayToTable(list.PreflightActionWidgets)[1]
            if U.ok(h) then
                local inner, ia = nil, nil
                pcall(function() inner = h.WBP_Input_Action end)
                pcall(function() ia = (U.ok(inner) and inner or h).InputAction end)
                if U.ok(ia) then
                    local nm = objName(ia)
                    out[nm] = out[nm] or {}
                    out[nm][#out[nm] + 1] = U.key(list)
                    n = n + 1
                end
            end
        end
    end
    if n == 0 then return nil, 0 end
    return out, n
end

---------------------------------------------------------------------------------------------------- keys
-- Keys per action from the player's control scheme (its raw IMC names) + P1's keyboard. iaKeys includes the throttle
-- (ignition prompt); keyToIas only the actions with a PC event (polled).
local function buildKeys(e)
    local names = rawImcNames(e.pc)
    local alt = false
    for _, n in ipairs(names) do if n == "IMC_Vehicle_Alternative" then alt = true end end
    local pad = alt and PAD_ALT or PAD_DEFAULT
    local iaKeys, k2ia = {}, {}
    for ia, ks in pairs(pad) do iaKeys[ia] = { table.unpack(ks) } end
    if e.pnum == 1 then
        for ia, ks in pairs(KB) do
            for _, k in ipairs(ks) do iaKeys[ia][#iaKeys[ia] + 1] = k end
        end
    end
    for ia, ks in pairs(iaKeys) do
        if EVENT_FN[ia] then
            for _, k in ipairs(ks) do
                k2ia[k] = k2ia[k] or {}
                k2ia[k][#k2ia[k] + 1] = ia
            end
        end
    end
    e.iaKeys, e.keyToIas, e.down = iaKeys, k2ia, {}
    e.scheme = alt and "Alternative" or "Default"
    e.imcs = table.concat(names, ",")
end

local fkeys = {}
local function keyDown(pc, name)
    name = DIGITAL[name] or name
    local k = fkeys[name]
    if not k then k = { KeyName = U.fname(name) }; fkeys[name] = k end
    local ok, v = pcall(function() return pc:IsInputKeyDown(k) end)   -- per-PC PlayerInput (pause.lua relies on it)
    return ok and v == true
end

---------------------------------------------------------------------------------------------------- verdict
local function setVerdict(e, v, why)
    if e.verdict == v then return end
    U.log(TAG, "P%d check input: %s -> %s (%s)", e.pnum, tostring(e.verdict or "watching"), tostring(v or "watching"),
        why)
    e.verdict, e.why = v, why
end

-- 0.6.0 (live finding F1, run G): inputfix adds P1's vehicle pad IMC to every guest's Enhanced Input, so a guest's own
-- InpActEvt_IA_Veh_* events fire natively (pause proven). State of that fix for this player: "ok" | "game" |
-- "pending" | "unverified" | "fail" | "off" | nil (inputfix.guestVehicleInput).
local function eiState(e)
    local okM, inputfix = pcall(U.mod, "inputfix")
    if not okM or type(inputfix) ~= "table" or type(inputfix.guestVehicleInput) ~= "function" then return nil end
    local ok, st = pcall(inputfix.guestVehicleInput, e.pc)
    return ok and st or nil
end

-- The guest's game path is expected to work: its PlayerInput maps check actions now, or inputfix just added the context
-- (the deferred rebuild has not shown up in EnhancedActionMappings yet).
local function nativeExpected(e)
    if e.mapOk and (e.mapHits or 0) > 0 then return true end
    local st = e.ei
    return st == "ok" or st == "game" or st == "pending"
end

-- Integration review 0.5.1: the "maps none of the check actions" shortcut is trusted only for a GUEST and only when
-- P1's own PlayerInput maps them (the probe discriminates). The game feeds its actions through GfnRawInputSubsystem
-- (run F probe: "raw->PlayerInput false"), so pc.PlayerInput may read 0 for P1 as well; an "inject" verdict on a
-- player whose game path works doubles every press (the second one fails the check). P1 is never injected from the
-- start ("always" aside): it is watched and only injected after IgnitionSilentPressesP1 silent check starts.
local function initialVerdict(s, e, mode)
    local detector = snap(e) ~= nil
    if not e.assist then return "game", "the mod does not assist this player (IgnitionMode)" end
    if mode == "off" then return "game", "IgnitionPadAssist off" end
    if mode == "always" then return "inject", "IgnitionPadAssist always" end
    if e.pnum ~= 1 and nativeExpected(e) then
        -- prefer the guest's own path: watched like P1 (a silent check start still falls back to injection)
        local why = string.format("its Enhanced Input maps %d check action(s), inputfix vehicle context %s: the game's "
            .. "own path is expected", e.mapHits or 0, tostring(e.ei))
        if detector then return nil, why .. "; watching its screen" end
        return "game", why .. "; no screen to verify against"
    end
    if e.pnum ~= 1 and e.mapOk and e.mapHits == 0 and s.p1MapHits and s.p1MapHits > 0 then
        e.injectByMap = true
        return "inject", string.format("its PlayerInput maps none of the check actions (P1's maps %d): the game's own "
            .. "path cannot fire", s.p1MapHits)
    end
    if detector then return nil, "watching its screen" end
    if e.pnum == 1 then return "game", "P1, no screen to verify against" end
    return "inject", "guest, no screen to verify against (runs E/F: guest IA events dead)"
end

---------------------------------------------------------------------------------------------------- inject
-- The PC event calls ITS cached "Pre Flight Check Component" (BP var, ObjectProperty): it must be the player's own
-- (e.comp = its car's PlayerState component, the BP's own source). Re-cached with SetupIgnitionBindings(); still
-- different -> written (cfg.IgnitionFixPcComp, default on). Logged once per player.
local function ensureComp(e)
    local want, k = U.key(e.comp), 0
    pcall(function() k = U.key(e.pc["Pre Flight Check Component"]) end)
    if k ~= 0 and k == want then return true end
    local before = k
    pcall(function() e.pc:SetupIgnitionBindings() end)       -- caches it from the PC's own car (BP, 0.1 s retry)
    pcall(function() k = U.key(e.pc["Pre Flight Check Component"]) end)
    local wrote = false
    if k ~= want and want ~= 0 and opt("IgnitionFixPcComp", true) ~= false then
        wrote = pcall(function() e.pc["Pre Flight Check Component"] = e.comp end)
        pcall(function() k = U.key(e.pc["Pre Flight Check Component"]) end)
    end
    if not e.compLogged then
        e.compLogged = true
        U.log(TAG, "P%d PC's Pre Flight Check Component was %s, own %s: now %s (rebind%s)", e.pnum, hex(before),
            hex(want), hex(k), wrote and " + write" or "")
    end
    return k == want
end

-- The PC's own action event with the IA object: the BP builds the soft reference and calls TestPreflightCheckInput.
local function inject(s, e, h)
    if not e.assist then return end
    local fn, ia = EVENT_FN[h.ia], iaObject(s, h.ia)
    if not fn or not ia then
        e.errors = e.errors + 1
        U.logEvery("ignpad.noia" .. e.pnum, 3000, TAG, "P%d %s: no PC event / IA object (fn %s, ia %s)", e.pnum,
            h.ia, tostring(fn), tostring(ia ~= nil))
        return
    end
    ensureComp(e)
    local ok, err = pcall(function() e.pc[fn](e.pc, {}, 0.0, 0.0, ia) end)
    e.ownAt = St.nowMs()
    if not ok then
        e.errors = e.errors + 1
        e.broken = tostring(err)
        U.warn(TAG, "P%d %s: PC event call failed: %s", e.pnum, h.ia, tostring(err))
        return
    end
    e.injected = e.injected + 1
    local after = snap(e)
    if after and e.snapPrev and after.w == e.snapPrev.w then
        if not sameSnap(after, e.snapPrev) then e.ownTransitions = e.ownTransitions + 1 end
        if after.succ > e.snapPrev.succ and e.snapPrev.cur ~= 0 then e.doneLists[e.snapPrev.cur] = true end
    end
    e.snapPrev = after or e.snapPrev             -- the screen change our call caused is not a game-path delivery
    if e.injected <= 16 or e.injected % 50 == 0 then
        -- F4c (run G): St.nowMs() is a float; "%d" of a non-integral float throws inside string.format and U.log then
        -- printed the raw format string + '|'-joined args. Every %d argument is an integer now.
        U.log(TAG, "P%d %s (%s) -> PC event, inject #%d (%d ms after the press)", e.pnum, h.ia, h.key, e.injected,
            math.floor(St.nowMs() - h.t))
    end
end

-- Is this action the first action of a check that is not done yet (a delivered press would start it)?
local function isStart(e, ia)
    if not e.first then return DEFAULT_FIRST[ia] == true end
    for _, lk in ipairs(e.first[ia] or {}) do
        if not e.doneLists[lk] then return true end
    end
    return false
end

-- Oldest press first; a press still waiting for its verdict holds the later ones (sequence order).
local function drain(s, e, now)
    local window = math.floor(tonumber(opt("IgnitionPadAssistWindowMs", 250)) or 250)
    -- a guest whose own path is expected: a replay waits IgnitionInjectDelayMs so pollPlayer can see the game's own
    -- reaction first (-> "game", nothing replayed): the native press and the replay never both reach the check
    local delay = nativeExpected(e) and math.max(0, tonumber(opt("IgnitionInjectDelayMs", 120)) or 120) or 0
    -- guests: one silent check start is enough (runs E/F: their action events are dead; the checks last ~5 s);
    -- P1 (whose game path works): IgnitionSilentPressesP1 before the mod replays anything
    -- 0.6.0 integration review: a guest whose own path is expected (F1) gets P1's threshold too (2+ distinct silent
    -- starts): one missed screen read must not switch a working guest to replays
    local p1Like = e.pnum == 1 or nativeExpected(e)
    local need = p1Like and (tonumber(opt("IgnitionSilentPressesP1", 3)) or 3)
        or (tonumber(opt("IgnitionSilentPresses", 1)) or 1)
    need = math.max(1, need)
    while #e.q > 0 do
        local h = e.q[1]
        if e.verdict == "inject" then
            if delay > 0 and now - h.t < delay then break end
            inject(s, e, h)
        elseif e.verdict == "game" then
            e.delivered = e.delivered + 1
        else
            if now - h.t < window then break end
            if h.s0 and h.s0.cur == 0 and isStart(e, h.ia) then
                e.silent = e.silent + 1
                e.silentIa[h.ia] = true
                local distinct = 0
                for _ in pairs(e.silentIa) do distinct = distinct + 1 end
                U.log(TAG, "P%d %s (%s): no screen reaction within %d ms while idle (silent %d/%d, %d action(s))",
                    e.pnum, h.ia, h.key, window, e.silent, need, distinct)
                local starts = 0                           -- distinct check-start actions still available
                if e.first then
                    for ia in pairs(e.first) do if isStart(e, ia) then starts = starts + 1 end end
                else
                    starts = 5
                end
                if e.silent >= need and distinct >= math.min(2, need, math.max(1, starts)) then
                    setVerdict(e, "inject", string.format("%d silent check starts", e.silent))
                    inject(s, e, h)
                end
            else
                e.ambiguous = e.ambiguous + 1
            end
        end
        table.remove(e.q, 1)
    end
end

local function pollPlayer(s, e, now)
    if not e.keyToIas then return end
    local underway = e.comp.bAreChecksUnderway == true
    local cur = snap(e)
    if cur and e.snapPrev and e.snapPrev.w == cur.w and cur.succ > e.snapPrev.succ and e.snapPrev.cur ~= 0 then
        e.doneLists[e.snapPrev.cur] = true          -- that list's check succeeded: its first action starts nothing now
    end
    if underway and cur and e.snapPrev and e.snapPrev.w == cur.w and not sameSnap(cur, e.snapPrev) then
        if now - (e.ownAt or -1e9) > OWN_MS then
            e.transitions = e.transitions + 1
            if e.verdict == "inject" then
                U.warn(TAG, "P%d: its screen changed without the mod (game path alive): injection stops", e.pnum)
            end
            setVerdict(e, "game", "its screen reacted to the game's own input path")
        else
            e.ownTransitions = e.ownTransitions + 1
        end
    end
    for key, ias in pairs(e.keyToIas) do
        local down = keyDown(e.pc, key)
        local was = e.down[key]
        e.down[key] = down
        if down and was == false and underway then          -- nil = first sample: a held key is not a press
            e.presses = e.presses + 1
            for _, ia in ipairs(ias) do e.q[#e.q + 1] = { t = now, ia = ia, key = key, s0 = e.snapPrev } end
        end
        if down and e.pnum == 1 and not key:find("^Gamepad_") and not e.kbSeen then
            e.kbSeen = true
            U.log(TAG, "P1 uses the keyboard (%s): its prompts are left to the game", key)
        end
    end
    e.snapPrev = cur
    if #e.q > 0 then drain(s, e, now) end
end

---------------------------------------------------------------------------------------------------- prompts
local cisClass = nil
local function cisOf(pc)
    if not U.ok(cisClass) then
        local ok, c = pcall(StaticFindObject, CIS_CLASS)
        cisClass = (ok and U.ok(c)) and c or nil
    end
    if not cisClass then return nil end
    local ok, sub = pcall(function() return U.SBL():GetLocalPlayerSubSystemFromPlayerController(pc, cisClass) end)
    if ok and U.ok(sub) then return sub end
    return nil
end

local function isPadPlayer(e)
    if e.pnum ~= 1 then return true end
    local okS, settings = pcall(U.mod, "settings")
    if okS and type(settings) == "table" and settings.get("KeyboardIsP1") == true then return false end
    return not e.kbSeen
end
M.isPadPlayer = isPadPlayer

local function promptTick(e, now)
    if opt("IgnitionPadPrompts", "pads") ~= "pads" or not isPadPlayer(e) then return end
    if now - (e.promptAt or -1e9) < 100 then return end
    e.promptAt = now
    if not U.ok(e.cis) then e.cis = cisOf(e.pc) end
    if not e.cis then
        U.logEvery("ignpad.nocis" .. e.pnum, 10000, TAG, "P%d prompts: no CommonInputSubsystem", e.pnum)
        return
    end
    local okC, cur = pcall(function() return e.cis:GetCurrentInputType() end)
    if not okC or cur == GAMEPAD then return end
    local okS, err = pcall(function() e.cis:SetCurrentInputType(GAMEPAD, false) end)
    e.forced = (e.forced or 0) + 1
    if e.forced == 1 or e.forced % 50 == 0 then
        U.log(TAG, "P%d prompts: CommonInput type %s -> Gamepad (x%d%s)", e.pnum, tostring(cur), e.forced,
            okS and "" or (", error " .. tostring(err)))
    end
end

local function padKeyFor(e, ia)
    for _, k in ipairs((e.iaKeys or {})[ia] or {}) do
        if k:find("^Gamepad_") then return k end
    end
    local st = PAD_DEFAULT[ia]
    return st and st[1] or nil
end

-- FixedDisplayKey on every input-action widget of this player's screen (engine-start prompt + each list's icons).
-- Once per widget instance; a rebuilt list gets new widgets and is done again.
function M.applyFixedKeys(e, screen)
    local m = opt("IgnitionFixedKeys", "guests")
    if m == "off" or (m == "guests" and e.pnum == 1) or not isPadPlayer(e) or not U.ok(screen) then return end
    e.fixedDone = e.fixedDone or {}
    local n, miss = 0, 0
    local function fix(iaw)
        local k = U.key(iaw)
        if k == 0 or e.fixedDone[k] then return end
        local ia = iaw.InputAction                            -- ObjectProperty<InputAction> (JMAP), not soft
        if not U.ok(ia) then return end                       -- set later by the BP: next tick
        local key = padKeyFor(e, objName(ia))
        e.fixedDone[k] = true
        if not key then miss = miss + 1; return end
        local ok = pcall(function() iaw:SetFixedDisplayKey({ KeyName = U.fname(key) }) end)
        if ok then n = n + 1 else miss = miss + 1 end
    end
    local function fixHolder(w)
        if not U.ok(w) then return end
        local inner = nil
        pcall(function() inner = w.WBP_Input_Action end)
        if U.ok(inner) then fix(inner) elseif U.isA(w, FUSE_IA) then fix(w) end
    end
    pcall(function() fixHolder(screen.WBP_Hud_Ignition_Input_Action) end)
    for _, list in ipairs(U.arrayToTable(screen.PreFlightCheckLists)) do
        if U.ok(list) then
            for _, w in ipairs(U.arrayToTable(list.PreflightActionWidgets)) do fixHolder(w) end
        end
    end
    if n > 0 or miss > 0 then
        U.log(TAG, "P%d prompts: %d input icon(s) set to pad keys (%d without a key)", e.pnum, n, miss)
    end
end

---------------------------------------------------------------------------------------------------- API
function M.begin()
    local s = S()
    s.active, s.players, s.t0 = true, {}, St.nowMs()
    local n, missing = eventFnsFound()
    s.fnFound, s.fnMissing = n, table.concat(missing, ",")
    U.log(TAG, "ignition: assist=%s silentPresses=%s windowMs=%s assistP1=%s prompts=%s fixedKeys=%s; PC events "
        .. "%d/9 found%s (no soft pointers: the PC's own action events are called)", assistMode(),
        tostring(opt("IgnitionSilentPresses", 1)) .. "/P1 " .. tostring(opt("IgnitionSilentPressesP1", 3)),
        tostring(opt("IgnitionPadAssistWindowMs", 250)),
        tostring(opt("IgnitionAssistP1", true)), tostring(opt("IgnitionPadPrompts", "pads")),
        tostring(opt("IgnitionFixedKeys", "guests")), n, n < 9 and (" (missing " .. s.fnMissing .. ")") or "")
end

local function probeLine(s, e)
    local pcComp = 0
    pcall(function() pcComp = U.key(e.pc["Pre Flight Check Component"]) end)
    local psComp = U.key(e.comp)
    U.log(TAG, "P%d input probe: scheme=%s imcs={%s} enhancedMappings=%s (%d total, %d check: %s) eiVehicleCtx=%s "
        .. "pcComp=%s psComp=%s same=%s events=%d/9 screen=%s detector=%s firstActions=%d verdict=%s (%s)", e.pnum,
        tostring(e.scheme), tostring(e.imcs), e.mapOk and "read" or "unreadable", e.mapTotal or 0, e.mapHits or 0,
        tostring(e.mapInfo), e.pnum == 1 and "p1" or tostring(e.ei), hex(pcComp), hex(psComp),
        tostring(pcComp ~= 0 and pcComp == psComp),
        s.fnFound or 0, U.ok(e.screen) and objName(e.screen) or "none", tostring(snap(e) ~= nil), e.firstN or 0,
        tostring(e.verdict or "watching"), tostring(e.why))
end

-- MAIN tick. list = { {pc=, pnum=, comp=, screen=, assist=bool}, ... }
function M.sync(list)
    local s = S()
    if not s.active then return end
    local mode, seen = assistMode(), {}
    for _, p in ipairs(list) do
        local k = U.key(p.pc)
        if k ~= 0 then
            seen[k] = true
            local e = s.players[k]
            if not e then
                e = { pc = p.pc, pnum = p.pnum, down = {}, q = {}, presses = 0, delivered = 0, injected = 0,
                      errors = 0, silent = 0, silentIa = {}, ambiguous = 0, transitions = 0, ownTransitions = 0,
                      doneLists = {} }
                s.players[k] = e
            end
            e.pc, e.pnum = p.pc, p.pnum
            e.assist = p.assist == true and (p.pnum ~= 1 or opt("IgnitionAssistP1", true) ~= false)
            if U.key(p.screen) ~= U.key(e.screen) then            -- new / other screen: re-read its lists
                e.screen, e.snapPrev, e.first, e.firstCount = p.screen, nil, nil, -1
            end
            if U.ok(p.comp) then
                e.comp = p.comp
                if not e.keyToIas then U.try(TAG, buildKeys, e) end
                -- 0.6.0: re-probed (IgnitionMapReprobeMs) until the checks start, and while a guest is replayed only
                -- because it mapped nothing (inputfix adds its vehicle context; the deferred rebuild shows up a
                -- frame later)
                local now = St.nowMs()
                local reprobe = not e.started or (e.verdict == "inject" and e.injectByMap == true)
                local every = tonumber(opt("IgnitionMapReprobeMs", 1000)) or 1000
                if not e.mapProbed or (reprobe and now - (e.mapAt or -1e12) >= every) then
                    e.mapProbed, e.mapAt = true, now
                    e.mapOk, e.mapTotal, e.mapHits, e.mapInfo = enhancedMappings(e.pc)
                    if e.pnum == 1 then s.p1MapHits = e.mapOk and e.mapHits or nil else e.ei = eiState(e) end
                    if e.started and e.injectByMap and e.verdict == "inject" and e.mapOk and (e.mapHits or 0) > 0 then
                        e.injectByMap, e.silent, e.silentIa = nil, 0, {}
                        setVerdict(e, nil, string.format("its Enhanced Input now maps %d check action(s) (inputfix "
                            .. "context %s): watching for the game's own path, replay only after a silent start",
                            e.mapHits, tostring(e.ei)))
                    end
                end
                if U.ok(e.screen) then
                    pcall(function()
                        local c = U.arrayCount(e.screen.PreFlightCheckLists)
                        if c ~= e.firstCount then e.firstCount = c; e.first, e.firstN = firstActions(e.screen) end
                    end)
                end
                if not e.started and p.comp.bAreChecksUnderway == true then
                    e.started = true
                    local v, why = initialVerdict(s, e, mode)
                    e.verdict, e.why = v, why
                    U.try(TAG, probeLine, s, e)
                end
            end
            if p.screen then U.try(TAG, M.applyFixedKeys, e, p.screen) end
        end
    end
    for k in pairs(s.players) do if not seen[k] then s.players[k] = nil end end
end

function M.fastTick()
    local s = S()
    if not s.active then return end
    local now = St.nowMs()
    for _, e in pairs(s.players) do
        if U.ok(e.pc) then
            U.tryEvery("ignpad.prompt", 5000, TAG, promptTick, e, now)
            if U.ok(e.comp) and e.started then U.tryEvery("ignpad.poll", 5000, TAG, pollPlayer, s, e, now) end
        end
    end
end

-- Why the mod's input for this player is broken (logged by ignition.lua; "auto" no longer auto-completes).
function M.broken(pc)
    local e = S().players[U.key(pc)]
    return e and e.broken or nil
end

local function summary(e)
    return string.format("P%d presses=%d verdict=%s (%s) injected=%d gamePath=%d screenChanges=%d (own %d) silent=%d "
        .. "ambiguous=%d errors=%d scheme=%s mapped=%s/%s eiVehicleCtx=%s prompts forced x%d broken=%s", e.pnum,
        e.presses,
        tostring(e.verdict or "watching"), tostring(e.why), e.injected, e.delivered, e.transitions, e.ownTransitions,
        e.silent, e.ambiguous, e.errors, tostring(e.scheme), tostring(e.mapHits), tostring(e.mapOk),
        e.pnum == 1 and "p1" or tostring(e.ei), e.forced or 0,
        tostring(e.broken))
end

function M.stop()
    local s = S()
    if not s.active then return end
    for _, e in pairs(s.players) do U.log(TAG, "pre-flight input summary: %s", summary(e)) end
    s.active, s.players = false, {}
end

function M.describe(out)
    local s = S()
    out(string.format("  ignpad: active=%s assist=%s events=%s/9", tostring(s.active), assistMode(),
        tostring(s.fnFound)))
    for _, e in pairs(s.players) do out("  " .. summary(e)) end
end

return M
