-- precision.lua: THE PRECISION DRIVING TEST'S GATE BONUS PER PLAYER (finding #86, Jules's gauntlet 2026-10-18 ~09:00
-- UTC, Crait EVT_SHK_PRE_Car_SPA_B_SHORT_02, separate copies P1 (AI) + P2 (Jules): "CHECKPOINT BONUS: 0.0s" all race
-- on P1's half, nothing on P2's, no gate bonus for anybody).
--
-- HOW THE GAME DOES IT (static, hf2 SWGR-Win64-Shipping.exe, capstone; JMAP Griffin-5.7.4-381121):
--   PrecisionDrivingRules (BP_ModeRules_PrecisionRun_C): Settings +0xd8 = PrecisionDrivingSettings
--   {TimeReductionForPassedGate +0x0 (1.5 in every shakedown precision event), TargetTimes, StartingSpeed},
--   Checkpoints +0xf0 (TArray<PrecisionRunCheckpoint>); unreflected +0x100 = the tracked car's previous location.
--   * Tick (vtable 0x1498fcea0 slot 0x348 = 0x142fd9f60): returns at once unless the race is started AND
--     GameState.PlayerArray.Num() == 1 (`cmp dword [gs+0x350], 1; jne` at 0x142fd9fd5): A SINGLE-PLAYER-ONLY MODE.
--     Then ps = PlayerArray[0], location = ps.PawnPrivate.RootComponent world location; for every checkpoint not yet
--     completed (+0x328) whose gate the segment previous -> current location crosses (0x1471de304: the gate's centre /
--     normal / half-width / height limits, unreflected +0x2b8..+0x324, set up by the checkpoint BP through the
--     reflected SetupGates(right, left) / SetupQuadGates(right, left, rightTop, leftTop)): the checkpoint is completed
--     (0x1430b7df8: +0x328 = 1 + its BP event OnCheckpointCompleted), ps.RaceEventComponent.BonusTime (+0xf4) +=
--     TimeReductionForPassedGate (0x142fda0bb), the race VM refreshed.
--   * OnLapCompleted (exec 0x1470d7416, any racer's lap): every checkpoint reset (0x1430b7df8(cp, false)).
--   * REC.BonusTime is the player's own clock bonus: the VM's event timer is (now - RaceStartTime) - BonusTime when
--     bWantsBonusTimeInEventTimer (0x140216d43), OnRacerFinished stamps EventFinishTime = time - BonusTime.
--   * The race VM (0x140216954): CurrentBonusTime (+0x198) = the REC.BonusTime of the FIRST LOCAL player's PlayerState
--     of GameState.PlayerArray (0x140216dae); WBP_Hud_EventBonusTime (kismet) rewrites "CHECKPOINT BONUS: {0}s" every
--     Tick from that global VM (SelectFloat(-x, x, x > 0)) and plays Anim_PassedGate when ITS RaceEventVM variable's
--     CurrentBonusTime changes.
--   => live #86: with P1 and P2 in the race PlayerArray holds 2 PlayerStates: the gate check never ran - no gate,
--     no bonus for anybody, the VM's 0.0 (the ~55.7 s between both players' raw and stamped times is the pause time,
--     not a bonus: the GO clock is the server clock); P2's copy of the popup was collapsed (hud.lua GuestHudCollapse).
--
-- WHAT THIS MODULE DOES (cfg.CouchPrecisionGates, a race-alone precision test with 2+ PlayerStates):
--   * the gate geometry: pre-hooks of PrecisionRunCheckpoint:SetupGates / SetupQuadGates keep each checkpoint's posts;
--   * every FAST tick, for every local player still racing: his car's segment previous -> current location against
--     every gate he has not passed in his current lap (M.crosses: the gate plane between the posts, either way, the
--     checkpoint's MaxPassingHeightAbove / Below or the quad gate's top); a gate passed = HIS REC.BonusTime +=
--     TimeReductionForPassedGate (the solo value: his result and, for P1, the game's timer / popup follow natively);
--     his gates re-arm when his own CurrentLapNumber changes (the native re-arms them on a lap);
--   * the popup: the BP writes the GLOBAL VM's (P1's) bonus into Txt_Time every Tick and BP hooks never fire (#106):
--     every guest popup shows a twin text written from HIS REC.BonusTime, the game's Txt_Time collapsed (the
--     CurrentEventTime post-hook is kept as an extra); each guest's widget gets a private RaceEventVM whose
--     CurrentBonusTime follows his bonus (his Anim_PassedGate plays on his own gates); hud.lua keeps the guests' copy
--     visible (M.ownsGuestCounter);
--   * the guests' event timer (hud.fastTimer): the race clock minus HIS bonus (M.guestClock).
--   The native never runs with 2 PlayerStates: no double count. The gates' own visual (OnCheckpointCompleted) is not
--   played (one gate actor for every copy).
-- [?] live: the SetupGates hooks fire at the checkpoints' BeginPlay (a hot reload mid-race misses them: WARN, no gate
--     bonus that race); the BP hook on CurrentEventTime fires per Tick; the VM follows P1 (probe line
--     "game VM follows").
-- Every game access is pcall-guarded; UObjects only inside one race world.
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "precision"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end

M.HOOK_GATES = "/Script/Griffin.PrecisionRunCheckpoint:SetupGates"
M.HOOK_QUAD = "/Script/Griffin.PrecisionRunCheckpoint:SetupQuadGates"
M.BONUS_WIDGET = "WBP_Hud_EventBonusTime"
M.HOOK_TEXT = "/Game/Griffin/UI/Widgets/HUD/WBP_Hud_EventBonusTime.WBP_Hud_EventBonusTime_C:CurrentEventTime"
M.VM_CLASS = "/Script/Griffin.RaceEventVM"

---------------------------------------------------------------------------------------------------- pure rules
local function v3(t) return { X = tonumber(t.X) or 0, Y = tonumber(t.Y) or 0, Z = tonumber(t.Z) or 0 } end

-- does the segment a -> b pass the gate g = {r = right post, l = left post, rt / lt = quad top posts (optional),
-- above / below = MaxPassingHeightAbove / Below (0 = no limit)}? Either way through; the plane is vertical through
-- the two posts. -> bool
function M.crosses(a, b, g)
    if not (a and b and g and g.r and g.l) then return false end
    local lx, ly = g.l.X, g.l.Y
    local dx, dy = g.r.X - lx, g.r.Y - ly
    local len2 = dx * dx + dy * dy
    if len2 < 1e-6 then return false end
    -- horizontal normal of the post line
    local nx, ny = -dy, dx
    local s0 = (a.X - lx) * nx + (a.Y - ly) * ny
    local s1 = (b.X - lx) * nx + (b.Y - ly) * ny
    if s0 == 0 and s1 == 0 then return false end
    if (s0 > 0 and s1 > 0) or (s0 < 0 and s1 < 0) then return false end
    local t = s0 / (s0 - s1)
    local px, py, pz = a.X + t * (b.X - a.X), a.Y + t * (b.Y - a.Y), a.Z + t * (b.Z - a.Z)
    local u = ((px - lx) * dx + (py - ly) * dy) / len2
    if u < 0 or u > 1 then return false end
    local gz = g.l.Z + u * (g.r.Z - g.l.Z)
    local top = nil
    if g.rt and g.lt then top = g.lt.Z + u * (g.rt.Z - g.lt.Z) end
    local above, below = tonumber(g.above) or 0, tonumber(g.below) or 0
    if above > 0 then top = math.min(top or math.huge, gz + above) end
    if top and pz > top then return false end
    if below > 0 and pz < gz - below then return false end
    return true
end

-- the popup's number as the BP formats it (SelectFloat(-x, x, x > 0), 1..3 decimals)
function M.popupValue(bonus)
    local x = tonumber(bonus) or 0
    if x > 0 then x = -x end
    local s = string.format("%.3f", x):gsub("0+$", "")
    if s:sub(-1) == "." then s = s .. "0" end
    if s == "-0.0" then s = "0.0" end
    return s
end

-- the BP's text with its number replaced by v (nil = no number in it)
function M.popupText(cur, v)
    if type(cur) ~= "string" then return nil end
    local out, n = cur:gsub("[%-%+]?%d+[%.,]%d+", v, 1)
    if n == 0 then out, n = cur:gsub("[%-%+]?%d+", v, 1) end
    if n == 0 then return nil end
    return out
end

---------------------------------------------------------------------------------------------------- gate geometry
local gates = {}          -- checkpoint key -> {r, l, rt, lt, gen}
local gstats = { setups = 0, quads = 0 }
function M._gates() return gates end
function M.gateStats() return gstats end

local function onSetup(cp, r, l, rt, lt)
    local c = U.unwrap(cp)
    if not U.ok(c) then return end
    local g = {}
    local ok = pcall(function()
        g.r, g.l = v3(U.unwrap(r)), v3(U.unwrap(l))
        if rt ~= nil and lt ~= nil then g.rt, g.lt = v3(U.unwrap(rt)), v3(U.unwrap(lt)) end
    end)
    if not ok then return end
    gates[U.key(c)] = g
    if g.rt then gstats.quads = gstats.quads + 1 else gstats.setups = gstats.setups + 1 end
end
M._onSetup = onSetup

---------------------------------------------------------------------------------------------------- race state
local S = { gen = nil }
local stats = { gates = 0, texts = 0, vms = 0 }
function M.stats() return stats end
M._state = function() return S end

local function rules()
    local r = nil
    pcall(function() local gm = U.gm(); if U.ok(gm) then r = gm.ModeRules end end)
    return U.ok(r) and r or nil
end

local kindMemo = { gen = nil, at = -1e12, on = false }
-- a race-alone precision test of this world? (re-read at most once a second)
function M.active()
    if opt("CouchPrecisionGates", true) ~= true then return false end
    local now = St.nowMs()
    if kindMemo.gen == St.worldGen and now - kindMemo.at < 1000 then return kindMemo.on end
    local ok, on = pcall(function()
        local cs = U.mod("couchsolo")
        return cs.raceAlone() and cs.info().kind == "precision"
    end)
    kindMemo.gen, kindMemo.at, kindMemo.on = St.worldGen, now, ok and on == true
    return kindMemo.on
end
M._forget = function() kindMemo.gen = nil end

local function humans()
    local out = {}
    pcall(function()
        local lps = U.localPlayers()
        if lps[1] and U.ok(lps[1].pc) then out[1] = { pc = lps[1].pc } end
    end)
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do if U.ok(e.pc) then out[e.pnum] = { pc = e.pc } end end
    end)
    for _, h in pairs(out) do pcall(function() h.ps = h.pc.PlayerState end) end
    return out
end

local function playerCount()
    local n = nil
    pcall(function() n = U.arrayCount(U.gs().PlayerArray) end)
    return n
end

local function state()
    if not M.active() then return nil end
    if S.gen == St.worldGen then return S end
    S = { gen = St.worldGen, p = {}, cps = nil, bonus = nil, native = nil, warned = {} }
    local r = rules()
    if r then pcall(function() S.bonus = tonumber(r.Settings.TimeReductionForPassedGate) end) end
    for pnum, h in pairs(humans()) do
        if U.ok(h.ps) then S.p[pnum] = { pnum = pnum, pc = h.pc, ps = h.ps, key = U.key(h.ps), pcKey = U.key(h.pc),
                                         passed = {}, lap = nil, prev = nil, n = 0 } end
    end
    local list = {}
    for pnum in pairs(S.p) do list[#list + 1] = "P" .. pnum end
    table.sort(list)
    U.log(TAG, "precision test: every player his own gates (%s), %s s per gate", table.concat(list, ", "),
        tostring(S.bonus))
    return S
end
M._stateNow = state

local function checkpoints(st)
    if st.cps then return st.cps end
    local r = rules()
    if not r then return nil end
    local list = {}
    pcall(function()
        for _, cp in ipairs(U.arrayToTable(r.Checkpoints)) do
            local c = cp
            if type(cp) == "userdata" and not U.ok(cp) then pcall(function() c = cp:get() end) end
            if U.ok(c) then list[#list + 1] = c end
        end
    end)
    if #list == 0 then return nil end                 -- the rules load them as they stream in: asked again
    local ok, miss = 0, 0
    for i, c in ipairs(list) do
        local g = gates[U.key(c)]
        if g then
            pcall(function()
                g.above = tonumber(c.MaxPassingHeightAbove) or 0
                g.below = tonumber(c.MaxPassingHeightBelow) or 0
            end)
            ok = ok + 1
        else
            miss = miss + 1
        end
        list[i] = { cp = c, k = U.key(c), i = i }
    end
    st.cps = list
    if miss > 0 then
        U.warn(TAG, "%d of %d gate(s) without their posts (SetupGates not seen: a reload mid-race?): those give no bonus "
            .. "this race", miss, #list)
    end
    U.log(TAG, "%d gate(s) of the rules, %d with their posts (%d SetupGates, %d SetupQuadGates seen)", #list, ok,
        gstats.setups, gstats.quads)
    return list
end

local function carLoc(p)
    local loc = nil
    pcall(function()
        local car = p.pc.Pawn
        if U.ok(car) then loc = v3(car:K2_GetActorLocation()) end
    end)
    return loc
end

local function rec(p)
    local r = nil
    pcall(function() r = p.ps.RaceEventComponent end)
    return U.ok(r) and r or nil
end

local function syncVm(p)
    if U.ok(p.vm) then pcall(function() p.vm.CurrentBonusTime = p.bonusNow or 0 end) end
end

-- one player's tick: his segment against his unpassed gates
local function playerTick(st, p, cps)
    local rc = rec(p)
    if not rc then return end
    local racing = true
    pcall(function() racing = U.callMethod(rc, "IsStillRacing") ~= false end)
    local loc = carLoc(p)
    if not racing or not loc then p.prev = nil; return end
    local lap = nil
    pcall(function() lap = tonumber(rc.CurrentLapNumber) end)
    if lap ~= p.lap then
        if p.lap ~= nil then
            U.log(TAG, "P%d lap %s: his %d gate(s) re-armed (bonus %.1f s so far)", p.pnum, tostring(lap), p.n,
                p.bonusNow or 0)
        end
        p.lap, p.passed = lap, {}
    end
    if p.prev then
        for _, c in ipairs(cps) do
            if not p.passed[c.k] then
                local g = gates[c.k]
                if g and M.crosses(p.prev, loc, g) then
                    p.passed[c.k] = true
                    p.n = p.n + 1
                    stats.gates = stats.gates + 1
                    local before, after = nil, nil
                    pcall(function()
                        before = tonumber(rc.BonusTime) or 0
                        rc.BonusTime = before + (st.bonus or 0)
                        after = tonumber(rc.BonusTime)
                    end)
                    p.bonusNow = after or p.bonusNow
                    syncVm(p)
                    if p.n <= 3 or p.n % 10 == 0 then
                        U.log(TAG, "P%d gate %d (lap %s): +%s s, his bonus %s s (%d gate(s))", p.pnum, c.i,
                            tostring(lap), tostring(st.bonus), after and string.format("%.1f", after) or "?", p.n)
                    end
                end
            end
        end
    end
    p.prev = loc
    pcall(function() p.bonusNow = tonumber(rc.BonusTime) or p.bonusNow end)
end

-- which player's bonus the game's VM shows (probe, logged on a change)
local function probeVm(st)
    local vm = nil
    pcall(function() vm = U.mod("couchsolo")._raceVM() end)
    if not U.ok(vm) then return end
    local cur = nil
    pcall(function() cur = tonumber(vm.CurrentBonusTime) end)
    if cur == nil or cur == 0 or cur == st.vmSeen then return end
    st.vmSeen = cur
    local who = {}
    for pnum, p in pairs(st.p) do
        if p.bonusNow and math.abs(p.bonusNow - cur) < 1e-3 then who[#who + 1] = "P" .. pnum end
    end
    table.sort(who)
    if (st.vmLogs or 0) < 3 then
        st.vmLogs = (st.vmLogs or 0) + 1
        U.log(TAG, "game VM follows %s (CurrentBonusTime %.1f)", #who > 0 and table.concat(who, "/") or "nobody", cur)
    end
end

local writeTwin                -- (the popups section) a guest's popup twin text from his own bonus

function M.fastTick()
    if St.phase ~= "RACING" then return end
    local st = state()
    if not st then return end
    if st.native == nil then
        local n = playerCount()
        if n == nil then return end
        st.native = n == 1
        U.log(TAG, "PlayerArray holds %d PlayerState(s): %s", n, st.native
            and "the game's own gate check runs (one player): nothing to do"
            or "the game's gate check is off (single-player only): every player's gates are counted here")
    end
    if st.native then return end
    local cps = checkpoints(st)
    if not cps then return end
    for _, p in pairs(st.p) do
        U.try(TAG, playerTick, st, p, cps)
        if p.twins then for _, t in pairs(p.twins) do U.try(TAG, writeTwin, p, t) end end
    end
    probeVm(st)
end

---------------------------------------------------------------------------------------------------- the popups
local function pOfPc(pc)
    local st = (S.gen == St.worldGen) and S or nil
    if not (st and U.ok(pc)) then return nil end
    local k = U.key(pc)
    for _, p in pairs(st.p) do if p.pcKey == k then return p end end
    return nil
end

-- post-hook of the BP's CurrentEventTime: the text the BP just wrote from the game's VM -> his own value
function M.onBonusText(ctx)
    local st = (S.gen == St.worldGen) and S or nil
    if not st or st.native ~= false then return end
    local w = U.unwrap(ctx)
    if not U.ok(w) then return end
    local p = nil
    pcall(function() p = pOfPc(w:GetOwningPlayer()) end)
    if not p then return end
    pcall(function()
        local item = w.WBP_Hud_BonusTime_Item
        local cur = item.Txt_Time:GetText():ToString()
        local want = M.popupText(cur, M.popupValue(p.bonusNow or 0))
        if want and want ~= cur then
            item:SetTimeText(FText(want))
            stats.texts = stats.texts + 1
        end
    end)
end

-- hud.lua (collapseGlobalParts): the guests' bonus popup stays visible (fed from his own bonus here)
function M.ownsGuestCounter(name)
    if type(name) ~= "string" or name:lower() ~= M.BONUS_WIDGET:lower() then return false end
    local st = state()
    return st ~= nil and st.native == false
end

-- hud.fastTimer: a guest's own event clock (seconds) while the gate bonus is his (nil = the game's)
function M.guestClock(e, el)
    local st = (S.gen == St.worldGen) and S or nil
    if not (st and st.native == false and e and type(el) == "number") then return nil end
    local p = st.p[e.pnum]
    if not p then return nil end
    local wants = true
    pcall(function()
        local vm = U.mod("couchsolo")._raceVM()
        if U.ok(vm) then wants = vm.bWantsBonusTimeInEventTimer == true end
    end)
    if not wants then return el end
    return el - (p.bonusNow or 0)
end

-- #106 (live 2026-10-18 10:03-10:05 UTC, Sentinel I EVT_SHK_PRE_Car_HSK_B_FWD, Jules = P2): P1 30 gates / 45 s, P2 10
-- gates / 15 s in the log, but P2's half showed P1's CHECKPOINT BONUS. Blueprint hooks never fire in this build
-- (main.lua; no "BP hooks work" line in that session): the CurrentEventTime post-hook above never ran, and the BP's Tick
-- rewrites WBP_Hud_BonusTime_Item.Txt_Time from the GAME's VM (GetRaceEventVM, not its own RaceEventVM variable) every
-- frame = P1's bonus ("game VM follows P1"). So every guest popup gets a TWIN FuseTextBlock next to Txt_Time in the
-- item's HB_TimerContent (hud.lua's race-timer twin, proven live 2026-10-11 on the same WBP_Hud_EventTime_Item_C), the
-- original collapsed (Anim_PassedGate binds Img_BorderPulse only: nothing shows it again), the twin written from HIS
-- REC.BonusTime with the original's own (localised) text as the template. The twins are kept in _G by popup widget, so
-- a hot reload reuses them instead of stacking a second one.
local TWINS = _G.SWGRCouch_precision_twins
if type(TWINS) ~= "table" then TWINS = {}; _G.SWGRCouch_precision_twins = TWINS end
M._twins = function() return TWINS end
local VIS_COLLAPSED = 1

local function styleTwin(tw, tx)
    pcall(function() tw:SetFont(tx.Font) end)
    pcall(function() tw:SetColorAndOpacity(tx.ColorAndOpacity) end)
    pcall(function() tw:SetShadowOffset(tx.ShadowOffset) end)
    pcall(function() tw:SetShadowColorAndOpacity(tx.ShadowColorAndOpacity) end)
    pcall(function() tw:SetJustification(1) end)                 -- the BP's SetJustification(Center)
    pcall(function() tw:SetLineHeightPercentage(1.15) end)       -- the BP's line height
    pcall(function() tw.Slot:SetVerticalAlignment(tx.Slot.VerticalAlignment) end)
    pcall(function() tw.Slot:SetPadding(tx.Slot.Padding) end)
end

-- the twin text of one guest's popup widget w (made once per widget), nil while it cannot be made
local function twinOf(p, w)
    local wk = U.key(w)
    local t = TWINS[wk]
    if t and U.ok(t.tw) and U.ok(t.tx) then
        if t.pnum ~= p.pnum then t.pnum, t.shown = p.pnum, nil end
        return t
    end
    TWINS[wk] = nil
    if (p.twinMiss or 0) >= 3 then return nil end
    local tx, par, tw = nil, nil, nil
    pcall(function() tx = w.WBP_Hud_BonusTime_Item.Txt_Time end)
    if U.ok(tx) then pcall(function() par = tx:GetParent() end) end
    local err = "no Txt_Time in the popup"
    if U.ok(tx) and U.ok(par) then
        local ok, e = pcall(function()
            tw = StaticConstructObject(tx:GetClass(), tx:GetOuter())
            par:AddChildToHorizontalBox(tw)
        end)
        err = tostring(e)
        if ok and U.ok(tw) then
            styleTwin(tw, tx)
            t = { tw = tw, tx = tx, pnum = p.pnum, shown = nil, tpl = nil }
            TWINS[wk] = t
            stats.twins = (stats.twins or 0) + 1
            U.log(TAG, "P%d's CHECKPOINT BONUS: twin text in place of the game's (the BP writes the game VM's = P1's "
                .. "bonus every frame; BP hooks never fire) (#106)", p.pnum)
            return t
        end
    elseif U.ok(tx) then
        err = "Txt_Time has no parent"
    end
    p.twinMiss = (p.twinMiss or 0) + 1
    if p.twinMiss >= 3 then
        U.warn(TAG, "P%d's CHECKPOINT BONUS twin not made (%s): his popup stays collapsed (no P1 value on his half)",
            p.pnum, err)
        pcall(function() w:SetVisibility(VIS_COLLAPSED) end)
    end
    return nil
end
M._twinOf = twinOf

-- the guest's popup text from HIS bonus; the game's Txt_Time (P1's) stays collapsed
writeTwin = function(p, t)
    if not (t and U.ok(t.tw) and U.ok(t.tx)) then return end
    pcall(function() if t.tx:GetVisibility() ~= VIS_COLLAPSED then t.tx:SetVisibility(VIS_COLLAPSED) end end)
    local cur = nil
    pcall(function() cur = t.tx:GetText():ToString() end)
    local v = M.popupValue(p.bonusNow or 0)
    local want = M.popupText(cur, v)
    if want then t.tpl = cur else want = M.popupText(t.tpl, v) end
    if not want then return end                                   -- the BP has not written its text yet
    if want ~= t.shown then
        if t.shown == nil then styleTwin(t.tw, t.tx) end          -- the BP's font is set by now
        local ok = pcall(function() t.tw:SetText(FText(want)) end)
        if ok then t.shown = want; stats.twinTexts = (stats.twinTexts or 0) + 1 end
    end
end

local function newVm(outer)
    local cls = U.class(M.VM_CLASS)
    if not U.ok(cls) then return nil end
    local ok, vm = pcall(StaticConstructObject, cls, outer)
    if not (ok and U.ok(vm)) then return nil end
    pcall(function() vm.bWantsBonusTimer = true end)
    return vm
end

-- MAIN: every guest's popup widget gets his private VM (its Anim_PassedGate follows his own gates)
function M.mainTick()
    if St.phase ~= "RACING" then return end
    local st = state()
    if not st or st.native ~= false then return end
    local H = St.hud
    if not (H and H.guests) then return end
    local hud = U.mod("hud")
    for _, e in pairs(H.guests) do
        local p = st.p[e.pnum]
        if p and e.pnum ~= 1 and U.ok(e.widget) then
            local list = {}
            pcall(function() list = hud.guestMembers(e, M.BONUS_WIDGET) end)
            for _, w in ipairs(list) do
                if U.ok(w) then
                    if not (U.ok(p.vm) and p.vmOuter == U.key(e.widget)) then
                        local vm = newVm(e.widget)
                        if vm then
                            p.vm, p.vmOuter = vm, U.key(e.widget)
                            stats.vms = stats.vms + 1
                            syncVm(p)
                        end
                    end
                    if U.ok(p.vm) then
                        local cur = nil
                        pcall(function() cur = w.RaceEventVM end)
                        if not (U.ok(cur) and U.key(cur) == U.key(p.vm)) then
                            local okS = pcall(function() w.RaceEventVM = p.vm end)
                            if type(e.hidden) == "table" then
                                local wk = U.key(w)
                                for i = #e.hidden, 1, -1 do if U.key(e.hidden[i]) == wk then table.remove(e.hidden, i) end end
                            end
                            pcall(function() w:SetVisibility(4) end)          -- SelfHitTestInvisible
                            U.log(TAG, "P%d's HUD %s: his own gate bonus (%.1f s) %s", e.pnum, M.BONUS_WIDGET,
                                p.bonusNow or 0, okS and "ok" or "FAILED")
                        end
                    end
                    local t = twinOf(p, w)
                    if t then
                        p.twins = p.twins or {}
                        p.twins[U.key(w)] = t
                        writeTwin(p, t)
                    end
                end
            end
        end
    end
end

function M.status()
    if S.gen ~= St.worldGen then return "precision: idle" end
    local parts = {}
    for pnum, p in pairs(S.p) do parts[#parts + 1] = string.format("P%d %d gate(s) %.1f s", pnum, p.n, p.bonusNow or 0) end
    table.sort(parts)
    return string.format("precision: native %s; %s; %d twin(s), %d twin text(s), %d hook text(s)", tostring(S.native),
        table.concat(parts, ", "), stats.twins or 0, stats.twinTexts or 0, stats.texts or 0)
end

function M.init()
    U.hook(M.HOOK_GATES, { pre = function(cp, r, l) U.try(TAG, onSetup, cp, r, l) end }, TAG)
    U.hook(M.HOOK_QUAD, { pre = function(cp, r, l, rt, lt) U.try(TAG, onSetup, cp, r, l, rt, lt) end }, TAG)
    U.hook(M.HOOK_TEXT, { post = function(ctx) U.try(TAG, M.onBonusText, ctx) end }, TAG)
    -- the checkpoints' SetupGates runs at their BeginPlay, inside the race world's load (before the phase poll sees
    -- the new world): the posts are dropped when the race is left, never at the world change
    St.on("world", TAG, function() S = { gen = nil }; kindMemo.gen = nil end)
    St.on("leaving", TAG, function()
        S = { gen = nil }; kindMemo.gen = nil; gates = {}
        for k in pairs(TWINS) do TWINS[k] = nil end                -- the race's HUDs go with the map
    end)
end

return M
