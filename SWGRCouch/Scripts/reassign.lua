-- reassign.lua (couch-fix72, player report #13): REASSIGN CONTROLLERS in the race pause menu.
--   Report (a player couple, 2P couch campaign, v1.0.2): "P1 and P2 can suddenly swap controllers (after disconnect /
--   reconnect)" (#7) -> "a pause-menu entry, usable even during a race: clears the assignments; the first pad to press
--   A = P1, the second = P2 (P3 / P4); P1 presses B to finish. Must work for ALL controllers including P1."
--   Root cause of the swap: a pad's ControllerId is its enumeration slot (XInput / SDL: device k+1 -> user k -> id k,
--   every session's join.lua device lines). A pad that reconnects can come back on the other pad's slot; nothing in the
--   game names a physical pad (couchseat.lua header), so the mod cannot tell. The players can: each presses A.
-- Flow (FAST loop, race phases, while the race pause is up):
--   1. pause.lua hands every WBP_PauseRacing_C to M.decorate (as restart.lua's): our own WBP_Vertical_Btn_C row
--      "Reassign Controllers" is appended to the pause list (FuseFilteredVerticalBox; nothing moved). Offered while
--      2+ local players race and the input DLL's PAD WATCH runs (inputfix.padWatch: the A / B edges of EVERY pad by
--      Slate user, before any LocalPlayer / CommonUI routing - the only reader that does not depend on which
--      PlayerController a pad drives now).
--   2. The row's press (the selected-toggle trick of restart.lua "twice") starts the flow: the presses seen in the
--      first ARM_MS are spent (the A that opened it). Then each pad's FIRST A takes the next seat: P1, P2, P3, P4
--      (KeyboardIsP1: the keyboard stays P1, the pads take P2..). Only pads that drive a local player now count (the
--      set of ids is kept: a permutation, no new LocalPlayer). The row and the screen's description box show whose
--      turn it is.
--   3. Finish: every seat pressed (cfg.ReassignAutoFinish), or P1's NEW pad presses B (the seats nobody pressed keep
--      their pad when it is free, else take a pad left over). Cancel: B before any A, cfg.ReassignTimeoutMs without a
--      press, the pause ending before every seat pressed: nothing changes.
--   4. Apply, once the pads have released A / B (no key held across the move): couch.applyPadIds (the swap's temp-id
--      path; refused while a shared-screen swap or a garage turn holds the ids) moves each seat's LocalPlayer onto
--      the pad its player pressed; padmap.set records ident (the id he is known by: P1 0, a guest his join id - seats,
--      credits, builds and progress keyed by it stay his) and pad; inputfix.refreshNative rewrites the DLL's owner
--      table at once. The cars keep their PlayerControllers and raw subsystems: steering / throttle (native filter, by
--      live id) and the Enhanced Input actions (afterburner press, engine switch: the engine, by live id) move to the
--      new pad together. The pause row gets the owner's focus back (the owner PC now hears another pad).
-- Rules: game thread only (FAST tick); every game call in pcall; kept UObjects U.ok-checked; no UIManager query; no
-- FindAllOf. cfg: ReassignControllers, ReassignTimeoutMs, ReassignAutoFinish, ReassignResume, ReassignLabel.
-- VERIFY(V-RA-01): 2P race, any player pauses: "REASSIGN CONTROLLERS added to WBP_PauseRacing_C (owner Pn ...)", the
--   row is last in the list, focusable, black (not grey).
-- VERIFY(V-RA-02): A on the row: "REASSIGN CONTROLLERS started by Pn: ..."; the row reads "PRESS A: PLAYER 1".
-- VERIFY(V-RA-03): A on the pad the P1 person holds, then on the P2 person's pad: "pad id x -> P1", "pad id y -> P2",
--   "CONTROLLERS REASSIGNED: P1 on pad id x, P2 on pad id y"; RESUME: each pad drives its own car (steer, throttle,
--   afterburner A, engine switch R3, abilities LB) and nothing of the other car.
-- VERIFY(V-RA-04): "[padmap] pad map set" names the moved players; after the race the paddock / results / map
--   screens are P1's pad's (the swap moves P1's PAD id), P2's credits and build are still his (couchrun by seat).
-- VERIFY(V-RA-05): cancel paths: B before any A / 15 s idle / RESUME before the last press: "cancelled (...)", ids as
--   before.
local C = require("consts")
local cfg = require("config")
local St = require("state")
local U = require("util")

local M = {}
local TAG = "reassign"

local function opt(k, d)
    local v = cfg[k]
    if v == nil or type(v) ~= type(d) then return d end
    return v
end

local PAUSE_RACING = "/Game/Griffin/UI/Screens/Pause/WBP_PauseRacing.WBP_PauseRacing_C"
local ARM_MS = 350               -- presses in the first ARM_MS of the flow are the press that opened it: spent
local RELEASE_MAX_MS = 1500      -- apply at the latest this long after the finish, keys held or not
local RACE_PHASES = { PRERACE = true, RACING = true }

local function R()
    St.reassign = St.reassign or { runs = 0, applied = 0 }
    return St.reassign
end

local function mod(name)
    local ok, m = pcall(U.mod, name)
    return (ok and type(m) == "table") and m or nil
end

local function padmap()
    local ok, m = pcall(require, "padmap")
    return (ok and type(m) == "table") and m or nil
end

local function keyboardIsP1()
    local ok, v = pcall(function() return require("settings").get("KeyboardIsP1") end)
    return ok and v == true
end

-- Slate user of a pad -> its ControllerId: +1 with bOffsetPlayerGamepadIds (KeyboardIsP1), as the native filter
local function padOffset()
    local ok, v = pcall(function() return U.GMS().bOffsetPlayerGamepadIds end)
    if ok and type(v) == "boolean" then return v and 1 or 0 end
    return keyboardIsP1() and 1 or 0
end

local function loaded(path)
    local ok, o = pcall(StaticFindObject, path)
    return (ok and U.ok(o)) and o or nil
end

local function pnumDesc(pc)
    if not U.ok(pc) then return "?" end
    for _, lp in ipairs(U.localPlayersRO()) do
        if U.key(lp.pc) == U.key(pc) then return "P" .. lp.index end
    end
    return "other"
end

---------------------------------------------------------------------------------------------------- pure
--- The new pads. cur = { {index, pad}, ... } in seat order (P1 first); picks = { pad, pad, ... } (picks[k] = the pad
--- that pressed k-th = seat k's). Seats with a pick get it; a seat without one keeps its own pad when no pick took
--- it, else the lowest pad left over. Only pads of cur count (a permutation of the current pads).
--- -> { [index] = pad } | nil, why
function M.plan(cur, picks)
    if type(cur) ~= "table" or #cur == 0 then return nil, "no seat" end
    picks = picks or {}
    if #picks > #cur then return nil, "more presses than seats" end
    local inUse, seen = {}, {}
    for _, c in ipairs(cur) do
        if type(c.pad) ~= "number" or inUse[c.pad] then return nil, "the seats' pads are not distinct" end
        inUse[c.pad] = true
    end
    for _, p in ipairs(picks) do
        if not inUse[p] then return nil, "pad id " .. tostring(p) .. " drives no seat" end
        if seen[p] then return nil, "pad id " .. tostring(p) .. " pressed twice" end
        seen[p] = true
    end
    local out, taken = {}, {}
    for k, c in ipairs(cur) do
        if picks[k] ~= nil then out[c.index] = picks[k]; taken[picks[k]] = true end
    end
    for k, c in ipairs(cur) do
        if picks[k] == nil and not taken[c.pad] then out[c.index] = c.pad; taken[c.pad] = true end
    end
    local free = {}
    for p in pairs(inUse) do if not taken[p] then free[#free + 1] = p end end
    table.sort(free)
    for _, c in ipairs(cur) do
        if out[c.index] == nil then out[c.index] = table.remove(free, 1) end
    end
    return out
end

--- The pads file's new A / B edges since base (pure): pads / base = { [uid] = {a, b, down} } -> list of
--- { uid, key = "a" | "b" } in uid order (A before B for one uid), and the new base
function M.edges(pads, base)
    local out, nb = {}, {}
    local uids = {}
    for uid in pairs(pads or {}) do uids[#uids + 1] = uid end
    table.sort(uids)
    for _, uid in ipairs(uids) do
        local e = pads[uid]
        local b0 = (base or {})[uid] or { a = 0, b = 0 }
        local a, b = tonumber(e.a) or 0, tonumber(e.b) or 0
        if a > (tonumber(b0.a) or 0) then out[#out + 1] = { uid = uid, key = "a" } end
        if b > (tonumber(b0.b) or 0) then out[#out + 1] = { uid = uid, key = "b" } end
        nb[uid] = { a = a, b = b }
    end
    for uid, b0 in pairs(base or {}) do if nb[uid] == nil then nb[uid] = b0 end end
    return out, nb
end

---------------------------------------------------------------------------------------------------- eligibility
local function padWatchOn()
    local IF = mod("inputfix")
    if not (IF and type(IF.padWatch) == "function") then return false end
    local ok, on = pcall(IF.padWatch)
    return ok and on == true
end

local function padsNow()
    local IF = mod("inputfix")
    if not (IF and type(IF.padPresses) == "function") then return {} end
    local ok, p = pcall(IF.padPresses)
    return (ok and type(p) == "table") and p or {}
end

-- the seats of the flow, in local-player order: { {index, pnum, lp, pc, pad = live id, ident}, ... } = P1 and the
-- JOINED guests (join.joinedList; a dormant local player - plugged, never joined - is no seat: it keeps its pad, or
-- takes one left over). Second list: the other local players (the plan's tail).
local function seatsNow()
    local out, rest = {}, {}
    local PM = padmap()
    local skipP1 = keyboardIsP1()
    local J = mod("join")
    local joined, haveList = {}, false
    if J and type(J.joinedList) == "function" then
        local ok, l = pcall(J.joinedList)
        if ok and type(l) == "table" then
            haveList = true
            for _, g in ipairs(l) do if U.ok(g.pc) then joined[U.key(g.pc)] = g.pnum end end
        end
    end
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) and type(e.ctrlId) == "number" then
            local ident = e.ctrlId
            if PM then
                local ok, v = pcall(PM.identOf, e)
                if ok and type(v) == "number" then ident = v end
            end
            local pn = (e.index == 1) and 1 or joined[U.key(e.pc)]
            local s = { index = e.index, pnum = pn or e.index, lp = e.lp, pc = e.pc, pad = e.ctrlId, ident = ident }
            local seat = (e.index == 1 and not skipP1) or (e.index ~= 1 and (pn ~= nil or not haveList))
            if seat then out[#out + 1] = s elseif not (skipP1 and e.index == 1) then rest[#rest + 1] = s end
        end
    end
    return out, rest
end

-- nil = offered, else why not
local function whyNot()
    if not opt("ReassignControllers", true) then return "ReassignControllers off" end
    if not RACE_PHASES[St.phase] then return "phase " .. tostring(St.phase) end
    if #(seatsNow()) < 2 then return "fewer than 2 players with a pad" end
    if not padWatchOn() then return "the input DLL's pad watch is not running (swgr_inputfilter.dll padwatch)" end
    local c = mod("couch")
    if c then
        local okS, sw = pcall(function() return c.swapped() end)
        if okS and sw == true then return "the pad ids are swapped for a shared screen" end
        local okG, g = pcall(function() return c.garageHeld() end)
        if okG and g == true then return "a garage turn holds the pad ids" end
    end
    return nil
end
M.whyNot = whyNot

---------------------------------------------------------------------------------------------------- the row
local function setRowText(st, text)
    local b = st.btn
    if not U.ok(b) then return end
    pcall(function() b:SetText(U.ftext(text)) end)
end

local function setDescription(st, text)
    local w = st.screen
    if not U.ok(w) then return end
    pcall(function()
        local txt = w.Txt_Description
        if U.ok(txt) then txt:SetText(U.ftext(text)) end
    end)
    pcall(function() w:ShowDescription() end)
end

local function makeRow(w, resume)
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    local b
    pcall(function() b = U.mod("ui").make("VerticalBtn", owner) end)  -- WBP_Vertical_Btn_C, owned like the screen
    if not U.ok(b) then return nil end
    pcall(function() b.IsInvert = true end)                         -- the pause rows are inverted (read by PreConstruct)
    pcall(function()
        local c = resume.LinearSelectBackgroundColor                -- the focus pill colour of RESUME
        b.LinearSelectBackgroundColor = { R = c.R, G = c.G, B = c.B, A = c.A }
    end)
    pcall(function()
        b:SetIsSelectable(true)
        b:SetIsToggleable(true)
    end)
    if not pcall(function() b:SetShouldSelectUponReceivingFocus(false) end) then
        pcall(function() b.bShouldSelectUponReceivingFocus = false end)
    end
    return b
end

-- appended to the pause list (nothing moved: restart.lua's PauseRestartPosition "end" path), switched on like RESUME
local function placeRow(w, btn, resume)
    local box
    pcall(function() box = w.FuseFilteredVerticalBox end)
    if not U.ok(box) then return false, "no FuseFilteredVerticalBox" end
    local has = false
    pcall(function() has = box:HasChild(btn) == true end)
    if has then return true, "already in the list" end
    local s
    pcall(function() s = box:AddChildToVerticalBox(btn) end)
    if not U.ok(s) then return false, "AddChildToVerticalBox failed" end
    pcall(function() s:SetHorizontalAlignment(C.E.HAlign.Left) end)
    pcall(function() btn:SetVisibility(C.E.Vis.Visible) end)
    local rf, ri = true, true
    pcall(function() rf = resume:GetIsFocusable() == true end)
    pcall(function() ri = resume:IsInteractionEnabled() == true end)
    if rf then pcall(function() btn:BP_SetIsFocusable(true) end) end
    if ri then pcall(function() btn:BP_SetIsInteractionEnabled(true) end) end
    local n, i = 0, -1
    pcall(function() n = math.tointeger(tonumber(box:GetChildrenCount())) or 0 end)
    pcall(function() i = math.tointeger(tonumber(box:GetChildIndex(btn))) or -1 end)
    return true, string.format("appended at %d of %d", i, n)
end

--- pause.lua: every new pause screen (pre-create in a split race, first sight otherwise). Idempotent per screen.
function M.decorate(w, how)
    local st = R()
    if not U.ok(w) then return end
    local k = U.key(w)
    if st.screenKey == k and st.placed then return end
    local cls = loaded(PAUSE_RACING)                                -- find-only: its instance holds it in memory
    local isRacing = false
    if cls then pcall(function() isRacing = w:IsA(cls) == true end) end
    if not isRacing then return end
    local why = whyNot()
    if why then
        if st.notWhy ~= why then
            st.notWhy = why
            U.log(TAG, "REASSIGN CONTROLLERS not offered: %s (V-RA-01)", why)
        end
        return
    end
    st.notWhy = nil
    local resume
    pcall(function() resume = w.Btn_ResumeRace end)
    if not U.ok(resume) then
        U.warn(TAG, "REASSIGN CONTROLLERS not added (%s): the screen has no Btn_ResumeRace (V-RA-01)", tostring(how))
        return
    end
    if U.ok(st.btn) then pcall(function() st.btn:RemoveFromParent() end) end
    local btn = makeRow(w, resume)
    if not U.ok(btn) then
        U.warn(TAG, "REASSIGN CONTROLLERS not added (%s): no WBP_Vertical_Btn_C (V-RA-01)", tostring(how))
        return
    end
    pcall(function() btn:SetText(U.ftext(opt("ReassignLabel", "Reassign Controllers"))) end)
    local okP, placed, txt = pcall(placeRow, w, btn, resume)
    st.screen, st.screenKey, st.btn, st.placed = w, k, btn, okP and placed == true
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    local logf = st.placed and U.log or U.warn
    logf(TAG, "REASSIGN CONTROLLERS added to WBP_PauseRacing_C (owner %s, %s): %s (V-RA-01)", pnumDesc(owner),
        tostring(how), okP and tostring(txt) or ("ERROR " .. tostring(placed)))
end

---------------------------------------------------------------------------------------------------- the flow
local function seatLabel(seat)
    return string.format("PLAYER %d", seat.pnum or seat.index)
end

local function prompt(st)
    local f = st.flow
    if not f then return end
    local nextSeat = f.seats[#f.picks + 1]
    local done = {}
    for i, pad in ipairs(f.picks) do done[#done + 1] = string.format("P%d = pad %d", f.seats[i].pnum, pad + 1) end
    if nextSeat then
        setRowText(st, "PRESS A: " .. seatLabel(nextSeat))
        setDescription(st, string.format("Each player presses A on the controller he holds: %s now.%s%s",
            seatLabel(nextSeat), #done > 0 and (" " .. table.concat(done, ", ") .. ".") or "",
            #f.picks > 0 and string.format(" P%d: B to finish.", f.seats[1].pnum) or " B cancels."))
    else
        setRowText(st, "CONTROLLERS SET")
        setDescription(st, table.concat(done, ", "))
    end
end

local function endFlow(st, text, label)
    st.flow = nil
    st.endedAt = St.nowMs()                 -- rel103: menubridge leaves the pause screen alone a moment longer
    setRowText(st, label or opt("ReassignLabel", "Reassign Controllers"))
    if text then setDescription(st, text) end
end

local function cancel(st, why)
    local f = st.flow
    if not f then return end
    U.log(TAG, "REASSIGN CONTROLLERS cancelled (%s): the pads stay as they were (V-RA-05)", tostring(why))
    endFlow(st, "Controllers unchanged.")
end

--- Starts the flow (the row's press; testcmd / the simulator call it directly). by = the PlayerController that asked.
--- -> true, or false + why
function M.start(by, why)
    local st = R()
    if st.flow then return false, "already running" end
    local no = whyNot()
    if no then
        U.log(TAG, "REASSIGN CONTROLLERS refused: %s", no)
        return false, no
    end
    local now = St.nowMs()
    local seats, rest = seatsNow()
    local base = {}
    for uid, e in pairs(padsNow()) do base[uid] = { a = tonumber(e.a) or 0, b = tonumber(e.b) or 0 } end
    st.flow = { atMs = now, armUntil = now + ARM_MS, lastMs = now, seats = seats, rest = rest, picks = {}, pickedUid = {},
                base = base, state = "pick", by = by, gen = St.worldGen, off = padOffset() }
    st.runs = (st.runs or 0) + 1
    local d = {}
    for _, s in ipairs(seats) do d[#d + 1] = string.format("P%d on pad id %d", s.pnum, s.pad) end
    U.log(TAG, "REASSIGN CONTROLLERS started by %s (%s): %s; each player presses A on his controller, P%d first (V-RA-02)",
        pnumDesc(by), tostring(why or "pause menu"), table.concat(d, ", "), seats[1].pnum)
    prompt(st)
    return true
end

local function inUse(f, pad)
    for _, s in ipairs(f.seats) do if s.pad == pad then return true end end
    return false
end

local function finish(st, why, now)
    local f = st.flow
    if not f or f.state ~= "pick" then return end
    f.state, f.finishMs, f.finishWhy = "release", now, why
    U.log(TAG, "REASSIGN CONTROLLERS: %s, applied once the pads are released", tostring(why))
end

local function onPress(st, uid, key, now)
    local f = st.flow
    local pad = uid + (f.off or 0)
    if key == "a" then
        if f.pickedUid[uid] then return end
        if not inUse(f, pad) then
            U.logEvery("reassign.nopad" .. uid, 5000, TAG, "pad id %d (Slate user %d) drives no player: ignored (a new pad "
                .. "joins from the lobby / the campaign's join, not here)", pad, uid)
            return
        end
        local seat = f.seats[#f.picks + 1]
        if not seat then return end
        f.picks[#f.picks + 1] = pad
        f.pickedUid[uid] = true
        f.lastMs = now
        U.log(TAG, "pad id %d -> P%d (was pad id %d) (V-RA-03)", pad, seat.pnum, seat.pad)
        prompt(st)
        if #f.picks >= #f.seats and opt("ReassignAutoFinish", true) then finish(st, "every player pressed A", now) end
    elseif key == "b" then
        if #f.picks == 0 then
            cancel(st, "B before any A")
        elseif f.picks[1] == pad then
            finish(st, string.format("P%d pressed B", f.seats[1].pnum), now)
        end
    end
end

local function keysReleased(f, pads)
    for _, s in ipairs(f.seats) do
        local e = pads[s.pad - (f.off or 0)]
        if type(e) == "table" and (tonumber(e.down) or 0) ~= 0 then return false end
    end
    return true
end

-- the screen's owner gets the focus on our row again (it hears another pad now: Slate keeps a focus under the user
-- it was given for)
local function refocusRow(st)
    local w, b = st.screen, st.btn
    if not (U.ok(w) and U.ok(b)) then return end
    local owner
    pcall(function() owner = w:GetOwningPlayer() end)
    if U.ok(owner) then pcall(function() b:SetUserFocus(owner) end) end
end

local function apply(st, now)
    local f = st.flow
    -- the plan: the seats (their picks), then every other local player (keeps his pad or takes one left over)
    local cur = {}
    for _, s in ipairs(f.seats) do cur[#cur + 1] = s end
    for _, s in ipairs(f.rest or {}) do cur[#cur + 1] = s end
    local plan, why = M.plan(cur, f.picks)
    if not plan then
        U.warn(TAG, "REASSIGN CONTROLLERS not applied: %s", tostring(why))
        endFlow(st, "Controllers unchanged.")
        return false
    end
    -- the live players again (a player gone since the start drops out; the plan is by local index)
    local want, list, changed, parts = {}, {}, false, {}
    local PM = padmap()
    for _, e in ipairs(U.localPlayers()) do
        if U.ok(e.pc) then
            local k = U.key(e.pc)
            local pad = plan[e.index]
            local ident = e.ctrlId
            if PM then
                local ok, v = pcall(PM.identOf, e)
                if ok and type(v) == "number" then ident = v end
            end
            if pad == nil then pad = e.ctrlId end                  -- not a seat (KeyboardIsP1's P1): his id stays
            want[k] = pad
            if pad ~= e.ctrlId then changed = true end
            list[#list + 1] = { lp = e.lp, index = e.index, ident = ident, pad = pad }
            parts[#parts + 1] = string.format("P%d on pad id %d", e.index, pad)
        end
    end
    if changed then
        local c = mod("couch")
        local ok, r = false, "couch.lua not loaded"
        if c and type(c.applyPadIds) == "function" then ok, r = c.applyPadIds(want, "REASSIGN CONTROLLERS") end
        if not ok then
            U.warn(TAG, "REASSIGN CONTROLLERS not applied: %s (V-RA-03)", tostring(r))
            endFlow(st, "Controllers unchanged.")
            return false
        end
    end
    if PM then pcall(PM.set, list, "REASSIGN CONTROLLERS") end
    local IF = mod("inputfix")
    if IF and type(IF.refreshNative) == "function" then pcall(IF.refreshNative, "REASSIGN CONTROLLERS") end
    pcall(function() St.emit("padmap", "reassign") end)
    st.applied = (st.applied or 0) + 1
    st.last = table.concat(parts, ", ")
    U.log(TAG, "CONTROLLERS REASSIGNED (%s): %s%s (V-RA-03)", tostring(f.finishWhy), st.last,
        changed and "" or " - nothing moved")
    endFlow(st, "Controllers reassigned: " .. st.last .. ".")
    refocusRow(st)
    if opt("ReassignResume", false) then
        local P = mod("pause")
        if P and type(P.resume) == "function" then pcall(P.resume, "REASSIGN CONTROLLERS") end
    end
    return true
end

local function pausedNow()
    local P = mod("pause")
    if not (P and type(P.isPaused) == "function") then return nil end
    local ok, v = pcall(P.isPaused)
    if ok then return v end
    return nil
end

local function flowTick(st, now)
    local f = st.flow
    if f.gen ~= St.worldGen or not RACE_PHASES[St.phase] then
        cancel(st, "the race world changed")
        return
    end
    local pads = padsNow()
    if f.state == "pick" then
        local ev, nb = M.edges(pads, f.base)
        f.base = nb
        if now >= f.armUntil then
            for _, x in ipairs(ev) do
                if not st.flow or st.flow.state ~= "pick" then break end
                onPress(st, x.uid, x.key, now)
            end
        end
        if not st.flow then return end
        if f.state == "pick" then
            if now - f.lastMs > math.max(1000, opt("ReassignTimeoutMs", 15000)) then
                cancel(st, string.format("no press for %d ms", math.floor(now - f.lastMs)))
                return
            end
            if pausedNow() == false then
                if #f.picks >= #f.seats then
                    finish(st, "every player pressed A (the pause ended)", now)
                else
                    cancel(st, "the pause ended before every player pressed A")
                    return
                end
            end
        end
    end
    if f.state == "release" and (keysReleased(f, pads) or now - f.finishMs >= RELEASE_MAX_MS) then
        apply(st, now)
    end
end

-- couch-fix76 (AUTO-172): the pause screen's description box follows the focused row through each row's own focus
-- event; our row has none, so the box kept the previous row's text ("Abandon tour? ...") until the flow started. The
-- row's focus is polled: on its focus edge (no flow running) the box gets our own line (cfg.ReassignDescription).
local function descTick(st, b)
    if st.flow then return end
    -- live 2026-10-24 12:43 (fix76): the pause row holds the Slate focus on its INNER button: HasAnyUserFocus() stays
    -- false while the row is highlighted, HasFocusedDescendants() / HasUserFocusedDescendants(owner) are true (and false
    -- on any other row)
    local f = false
    pcall(function() f = b:HasFocusedDescendants() == true end)
    if not f then pcall(function() f = b:HasAnyUserFocus() == true end) end
    if f and not st.descShown then
        setDescription(st, opt("ReassignDescription", "Controllers swapped? Each player presses A on the controller "
            .. "he holds, P1 first. B cancels."))
        U.log(TAG, "REASSIGN CONTROLLERS row focused: its description shown (AUTO-172)")
    end
    st.descShown = f
end

-- the row's press: the selected-toggle trick (restart.lua twiceTick)
local function rowTick(st)
    local b = st.btn
    if not U.ok(b) then return end
    if not U.ok(st.screen) then st.btn, st.screen, st.placed, st.descShown = nil, nil, false, false; return end
    if opt("ReassignDescribeRow", true) then descTick(st, b) end
    local sel = false
    pcall(function() sel = b:GetSelected() == true end)
    if not sel then return end
    pcall(function() b:SetIsSelected(false, false) end)
    if st.flow then return end                         -- an A while the flow runs is a pick (pad watch), nothing else
    local by
    local P = mod("pause")
    if P and type(P.controller) == "function" then pcall(function() by = P.controller() end) end
    M.start(by, "pause menu")
end

--- FAST loop (main.lua, race phases, after restart.fastTick)
function M.fastTick()
    local st = R()
    local now = St.nowMs()
    U.try(TAG, rowTick, st)
    if st.flow then U.try(TAG, flowTick, st, now) end
end

--- MAIN loop, every phase: a pad map restored from a hot reload is matched to the live local players
function M.mainTick()
    local st = R()
    if st.pendingMap then
        local v = st.pendingMap
        st.pendingMap = nil
        local PM = padmap()
        if PM then U.try(TAG, PM.decode, v) end
    end
end

function M.status()
    local st = R()
    local PM = padmap()
    return string.format("reassign: runs %d, applied %d, flow %s, last %s; padmap %s", st.runs or 0, st.applied or 0,
        st.flow and st.flow.state or "none", tostring(st.last), PM and PM.describe() or "?")
end

-- hot reload: the pad map (ids live on the LocalPlayers, which survive a Lua reload)
function M.persistShared(put)
    local PM = padmap()
    if PM then put("reassign.padmap", PM.encode()) end
end
function M.restoreShared(get)
    local v = get("reassign.padmap")
    if type(v) == "string" and v ~= "" then
        R().pendingMap = v
        U.log(TAG, "hot reload: a pad map (%s) to restore against the live local players", v)
    end
end

function M.init()
    St.on("phase", TAG, function(new)
        local st = R()
        if st.flow and not RACE_PHASES[new] then cancel(st, "phase " .. tostring(new)) end
        if new == "LOADING" or new == "FRONTEND" then st.btn, st.screen, st.screenKey, st.placed = nil, nil, nil, false end
    end)
    U.log(TAG, "init: REASSIGN CONTROLLERS %s (timeout %d ms, auto finish %s, resume %s)",
        opt("ReassignControllers", true) and "on" or "off", opt("ReassignTimeoutMs", 15000),
        tostring(opt("ReassignAutoFinish", true)), tostring(opt("ReassignResume", false)))
end

return M
