-- couchfence.lua (couch-rewards2 STEP 2, 2026-10-17): ONLY P1's PAD PRESSES P1's REWARD FLOW.
-- P1's post-race reward screens (the holder, the stage hub, CREDITS BREAKDOWN, FAULTS, CHOOSE AN UPGRADE) belong to the
-- LAST local PC (the UIManager's owner = a guest). couch.lua swaps the pad ids for them (P1's pad on the owner's id 0)
-- and parks P1's PC (id 6), so the owner's own pad reaches no LocalPlayer - but its Slate user is still there:
--   * CommonUI's activation of a guest-owned screen also focuses the owner's PHYSICAL pad (memory: "a new guest screen
--     while swapped needs its own refocus"; tools/sim game.lua G.livePhysFocus), and a parked pad's Slate accept clicks
--     the CommonButton it focuses (the live 2026-10-16 node-map leak: P2's A picked P1's node);
--   * couch.lua sinks that pad only at the swap and at a NEW top screen, never while a guest area is open
--     (areaHoldsPad), and couchpanel stops holding a guest's focus once he is DONE in his area. P2 claims his card
--     first, P1's flow goes on (hub -> credits -> hub): his pad is free to land on P1's WBP_Hero_Btn / WBP_Collect_Btn.
-- (The analysis' "P2 A -> RewardsHub WBP_Hero_Btn (owner focus): clicked" lines at 20:00:09 / 20:00:14 / 20:00:15 /
-- 20:06:38 were menubridge's clicks for the PC holding pad id 0 while the ids were swapped = P1's own pad, labelled by
-- that PC (P2's): menubridge's log now says so. The Slate path above is the guest pad's real way in.)
-- Every FAST tick while one of P1's reward screens is up (POSTRACE, couch on): any focus inside it that is not P1's pad
-- (the holder of pad id 0) is a guest's - his own reward area takes it back when he is still choosing there, else an
-- invisible sink of the guests' own (couch.sinkGuestPad). The parked pad has no PC to ask: while P1's screen holds a
-- focus, the parked pad must sit on its home (his choosing area's button or the guests' sink, read with
-- couch.parkedFocus = some user, no local player's): anywhere else it is sent home (one forced couch.withPadId).
-- menubridge: P1's reward screens are bridged for the PC holding pad id 0 only (any couch state).
-- FINDING #42 (live 2026-10-17 22:07:17-22:07:44, 433 moves in 27 s, "the parked pad: on the sink" each tick): the
-- parked pad was sent home on NO evidence - "not readable on its home" while P1's own pad focused his screen. Its home
-- read never came back true after a move (the guests' sink focus does not read as held there, and the swap parks that
-- pad on its OWN sink, swap.sink, at the swap and every new shared screen: not a home of the fence), so the fence moved
-- it every FAST tick, fighting the swap's parking. Now (fenceParked): a focus inside P1's screen that no local player's
-- user holds (only the parked pad can be there), or the parked pad on the screen's own focus target = moved at once;
-- while its home reads back, off home = sent home as before; once a move did not read back home on the next pass, the
-- read is blind there and the pad moves only when a probe of its own Slate user (P1's PC on its id for one call,
-- couch.withPadId, at most one per 500 ms) finds it inside P1's screen. Anywhere else (the swap's sink): left alone.
local U = require("util")
local St = require("state")
local cfg = require("config")

local M = {}
local TAG = "couchfence"

-- class-name prefixes of P1's reward flow (never a guest's own copies: couchpanel's widgets are not activated)
M.P1_REWARD = { "WBP_PostRace_Cam_Holder", "WBP_PostRace_RewardsHub", "WBP_PostRace_Rewards_", "WBP_PostRace_Cam_Rewards" }
function M.isP1Reward(cls)
    if type(cls) ~= "string" then return false end
    for _, p in ipairs(M.P1_REWARD) do
        if cls:sub(1, #p) == p then return true end
    end
    return false
end

local S = { fenced = 0, probes = 0, blind = false }
local parkedOnTarget             -- (defined below the probe)
local PROBE_MS = 500             -- at most one probe of the parked pad's Slate user per 500 ms (withPadId's own limit)

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local function couch() local c = package.loaded["couch"]; return type(c) == "table" and c or nil end
local function panel() local c = package.loaded["couchpanel"]; return type(c) == "table" and c or nil end

-- the local PC holding pad id 0 (P1's physical pad, wherever the swap put it)
local function holderOf0()
    local GS = U.cdo("GameplayStatics")
    for _, lp in ipairs(U.localPlayers()) do
        local ok, id = pcall(function() return GS:GetPlayerControllerID(lp.pc) end)
        if ok and id == 0 then return lp.pc end
    end
    return nil
end
M._holderOf0 = holderOf0

local function inside(w, pc)
    local has = false
    pcall(function() has = w:HasUserFocusedDescendants(pc) == true end)
    return has
end

-- a guest's area still choosing for pad id `ctrlId`: (his selected button, all his buttons), else nil
local function areaButtons(ctrlId)
    local cp = panel()
    if not (cp and cp.isOpen and cp.isOpen() == true and cp._panels) then return nil end
    for _, P in ipairs(cp._panels()) do
        if P.ctrlId == ctrlId and not P.done and not P.gone and not P.mirror and type(P.btns) == "table" then
            local b = P.btns[P.sel or 1] or P.btns[1]
            if U.ok(b) then return b, P.btns end
        end
    end
    return nil
end

local function note(ctrlId, why, ok)
    S.fenced = S.fenced + 1
    U.logEvery("couchfence." .. tostring(ctrlId), 3000, TAG, "pad %s's focus was inside P1's reward screen (%s) - %s (%d so far)",
        tostring(ctrlId), why, ok and "moved" or "move FAILED", S.fenced)
end

-- the pad (id; pc = the PC carrying it, nil = parked) onto his own area (still choosing there) or the guests' sink
local function giveBack(ctrlId, pc, why)
    local cp, c = panel(), couch()
    local b = areaButtons(ctrlId)
    local ok = false
    if b and cp.kit and cp.kit.padSetFocus then
        ok = cp.kit.padSetFocus(b, ctrlId, pc, true) == true
        why = why .. ": back on his own area"
    elseif c and c.sinkGuestPad then
        ok = c.sinkGuestPad(ctrlId, pc, why) == true
        why = why .. ": on the sink"
    end
    note(ctrlId, why, ok)
    return ok
end

-- the parked pad holds its proper place: his choosing area's button, else the guests' sink (cheap reads)
local function parkedHome(c, ctrlId)
    local b, all = areaButtons(ctrlId)
    if b then
        -- any of his own buttons (his D-pad moves between them before couchpanel's tick reads the new selection)
        for _, x in ipairs(all) do
            local has = false
            if U.ok(x) then pcall(function() has = c.parkedFocus(x) == true end) end
            if has then return true end
        end
        return false
    end
    return c.guestSinkHeld and c.guestSinkHeld(ctrlId) == true
end

-- the parked pad's focus read through its own Slate user (P1's PC on its id for this one call, couch.withPadId: not
-- forced, rate-limited). -> the class of the P1 reward screen holding it, false = in none of them, nil = not read
local function probeParked(c, parkedId, scr)
    if not c.withPadId then return nil end
    local where = nil
    local ran = c.withPadId(parkedId, function(p1)
        where = false
        for _, e in ipairs(scr) do
            if U.alive(e.w) and inside(e.w, p1) then where = e.cls; return end
        end
    end)
    S.probes = S.probes + 1
    if not ran then return nil end
    return where
end

-- the screen's desired focus target (one GetDesiredFocusTarget per screen per second, cached by screen)
local TARGET_MS = 1000
local function targetOf(e)
    local now = St.nowMs()
    S.tg = S.tg or {}
    local k = e.k or U.key(e.w)
    local t = S.tg[k]
    if not t or now - t.at >= TARGET_MS or (t.w ~= nil and not U.alive(t.w)) then
        local w = nil
        pcall(function() w = e.w:GetDesiredFocusTarget() end)
        t = { w = U.ok(w) and w or nil, at = now }
        S.tg[k] = t
    end
    return t.w
end
parkedOnTarget = function(c, e)
    local t = targetOf(e)
    if not (t and c.parkedFocus) then return false end
    local ok, has = pcall(c.parkedFocus, t)
    return ok and has == true
end

-- the parked pad (no PC to ask) while P1's screens hold a focus. `unowned` = a focus inside one of them that no local
-- player's user holds, or the parked pad on a screen's own focus target: it IS inside, moved at once. Otherwise (P1's
-- own focus is in there too, so the screen cannot say whose it is): while its home reads back, off home = sent home
-- (the cheap read); once a move did NOT read back home on the next pass (live #42: 433 moves), the home read is blind
-- there and the pad moves only when a probe of its own Slate user finds it inside (at most one per PROBE_MS).
local function fenceParked(c, parkedId, scr, unowned)
    local now = St.nowMs()
    if parkedHome(c, parkedId) then
        S.movedAt = nil
        if S.blind then
            S.blind = false
            U.dbg(TAG, "pad %s (parked): its home reads back again", tostring(parkedId))
        end
        return
    end
    if unowned then
        giveBack(parkedId, nil, unowned .. ", the parked pad")
        S.movedAt = now
        return
    end
    if not S.blind then
        if not S.movedAt then
            giveBack(parkedId, nil, scr[1].cls .. ", the parked pad")
            S.movedAt = now
            return
        end
        -- sent home on the last pass and its home still does not read: stop fighting (the swap's own parking, a home
        -- this read cannot see) - from now on only on evidence
        S.blind = true
        S.blindN = (S.blindN or 0) + 1
        U.log(TAG, "pad %s (parked): its home does not read back after a move (%s) - moved only when a probe finds it inside P1's screen now",
            tostring(parkedId), scr[1].cls)
    end
    if now < (S.probeAt or -1e12) then return end
    S.probeAt = now + PROBE_MS
    local where = probeParked(c, parkedId, scr)
    if where then giveBack(parkedId, nil, where .. ", the parked pad (probed)") end
end

-- one FAST tick (couchpanel.fastTick calls it first)
function M.tick()
    if opt("CouchRewardFence", true) == false or St.phase ~= "POSTRACE" then return end
    local c = couch()
    if not (c and c.active and c.active() == true) then return end
    local okQ, q = pcall(c.isQuiet)
    if okQ and q == true then return end
    local scr = {}
    for _, e in ipairs(c.activeScreens()) do
        if M.isP1Reward(e.cls) and U.alive(e.w) then scr[#scr + 1] = e end
    end
    if #scr == 0 then S.blind, S.movedAt, S.tg = false, nil, nil; return end
    local h0 = holderOf0()
    local swapped = c.swapped and c.swapped() == true
    local parkedId = c.parkedFor and c.parkedFor() or nil
    local GS = U.cdo("GameplayStatics")
    local focusedP1 = false
    local unowned = nil          -- a P1 screen holding a focus that no local player's user holds
    for _, e in ipairs(scr) do
        local w = e.w
        local any = false
        pcall(function() any = w:HasFocusedDescendants() == true end)
        if any then
            focusedP1 = true
            local owned = false
            -- a local PC's pad inside (not the holder of pad id 0 = P1's pad): a guest on his own id, or (plain swap,
            -- not parked) P1's PC carrying the screen owner's pad; P1's parked PC (id 6) only ever holds the sink
            for _, lp in ipairs(U.localPlayers()) do
                local pc = lp.pc
                if U.ok(pc) and inside(w, pc) then
                    owned = true
                    if not (U.ok(h0) and U.key(pc) == U.key(h0)) then
                        local okI, id = pcall(function() return GS:GetPlayerControllerID(pc) end)
                        giveBack(okI and id or nil, pc, string.format("%s, %s", e.cls, swapped and "ids swapped" or "ids normal"))
                    end
                end
            end
            if not owned then
                unowned = unowned or e.cls
            elseif parkedId ~= nil and not unowned and parkedOnTarget(c, e) then
                -- P1's focus is in there too: the parked pad on the screen's own focus target (where CommonUI's
                -- activation puts the owner's physical pad) is still read without a trip
                unowned = e.cls
            end
        end
    end
    if parkedId ~= nil and focusedP1 then fenceParked(c, parkedId, scr, unowned) end
end

function M.status() return string.format("couchfence: %d focus move(s), %d probe(s)", S.fenced, S.probes) end
function M._state() return S end
function M.init() end
return M
