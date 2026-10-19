-- couchseat.lua: COUCH SEATS - a guest's run progress belongs to his SEAT, not to his pad (FINDING #43, overnight
-- 2026-10-18). The guests' saved progress (couchrun's couch-run.txt + checkpoint journal: credits, build, parts,
-- garage, reward flow, faults, shop stock, side bet; garage.lua's guest-garage.txt) was keyed by the pad's ControllerId
-- (couchrun G.players[ctrlId]). The ControllerId is the pad's enumeration slot: after a relaunch P2's pad came up on
-- ctrlId 1 instead of 2, his payouts went to yesterday's ctrlId-1 record and tonight's progress "vanished" (it stayed
-- under ctrlId 2). The live file then held two "P2" records.
--
-- A SEAT is a place in the couch run: seat 2 = the first guest to join (P2), seat 3 the next (P3), seat 4 (P4). P1 is
-- seat 1 and never stored here. Rules:
--   * JOIN (join.lua, at the join press; also at CONTINUE: the lobby join that precedes it): a pad that joins takes a
--     seat whatever its ControllerId / vendor / slot: its own seat if it still holds one, else the seat of a joined
--     guest whose pad is DISCONNECTED (a pad swap: the new pad sits down in the seat, the old slot is un-joined by
--     join.lua), else the lowest free seat. The seat's progress comes with it (couchrun / garage look records up by
--     seat).
--   * A disconnect / reconnect keeps the seat (the slot stays joined); so does every pad-id swap couch.lua makes.
--   * LEAVE (hold B: join.campaignLeave, the lobby's B, F7): the seat is free again; its progress stays in the file for
--     the run, so the next pad that joins into that seat gets it back (the lowest free seat = the one just left, when
--     nobody sat down there in between).
--   * The map ControllerId -> seat lives in memory (St.join.seats) for the game process (a hot reload keeps it:
--     join.persistShared "join.seats"). A NEW process starts empty.
--   * PAD MEMORY (couch-fix31, audit 3-4P: "P3 pressing A before P2 takes P2's credits / build"): every seat taken is
--     also written to couch-run.txt (couchrun padSeats {[ControllerId] = seat}). After a relaunch a pad that joins
--     sits down in the seat ITS ControllerId held last time when that seat is free, whatever the join order; a free
--     seat remembered for ANOTHER pad that is here (a known slot, not seated yet in this process) is passed over, so
--     a newcomer never takes it (a guest who left in this session keeps no seat: LEAVE above). The ControllerId is the only pad identity the game gives Lua (InputDeviceSubsystem's hardware id only
--     names the device kind): pads that come back on other slots fall back to join order, as before. A file without
--     padSeats (before couch-fix31) = join order once; the memory fills as the pads sit down.
--     cfg.CouchSeatPadMemory = false: join order only (the memory is still written).
-- The seat number is not the display number: join.joinedList's pnum stays the guest's rank in view order (split
-- quadrant, colours, HUD tags). They are the same until a guest in a middle seat leaves while a higher one stays (P2
-- leaves, P3 stays: shown as "P2" in a 2-player view, his progress is still seat 3's). Logs say "P<pnum> (seat <n>)"
-- when they differ.
local St = require("state")
local U = require("util")
local cfg = require("config")

local TAG = "couchseat"
local M = {}
local FIRST, LAST = 2, 4

local function reg()
    St.join = St.join or {}
    local r = St.join.seats
    if type(r) ~= "table" or type(r.of) ~= "table" or type(r.at) ~= "table" then
        r = { of = {}, at = {} }
        St.join.seats = r
    end
    r.sat = type(r.sat) == "table" and r.sat or {}       -- the ControllerIds seated at least once in this process
    return r
end

-- couchrun's pad memory (nil: unavailable; use = false: cfg.CouchSeatPadMemory off - still written, never used)
local function mem(use)
    if use ~= false and cfg.CouchSeatPadMemory == false then return nil end
    local ok, CR = pcall(U.mod, "couchrun")
    if ok and type(CR) == "table" and type(CR.padSeatOf) == "function" and type(CR.rememberPadSeat) == "function" then
        return CR
    end
    return nil
end

local function set(r, id, seat)
    local old = r.of[id]
    if old ~= nil and r.at[old] == id then r.at[old] = nil end
    r.of[id], r.at[seat] = seat, id
    r.sat[id] = true
    local CR = mem(false)
    if CR then pcall(CR.rememberPadSeat, id, seat) end
end

-- the seat a ControllerId holds now, or nil
function M.of(ctrlId)
    local id = tonumber(ctrlId)
    if id == nil then return nil end
    return reg().of[id]
end

-- the ControllerId sitting in a seat now, or nil
function M.holder(seat) return reg().at[tonumber(seat) or -1] end

local function freeSeat(r, prefer, skip)
    skip = skip or {}
    prefer = tonumber(prefer)
    if prefer and prefer >= FIRST and prefer <= LAST and r.at[prefer] == nil and not skip[prefer] then return prefer end
    for s = FIRST, LAST do if r.at[s] == nil and not skip[s] then return s end end
    return nil
end

-- PAD MEMORY: the free seats remembered for another pad that is here now (a known slot) and has not sat down in this
-- process yet (after a relaunch; a guest who LEFT in this session keeps nothing: his seat goes to the next pad, as
-- before) -> {[seat] = ctrlId}
local function reservedFor(r, id, CR)
    local out = {}
    local okT, t = pcall(CR.padSeats)
    if not (okT and type(t) == "table") then return out end
    local slots = type(St.join) == "table" and type(St.join.slots) == "table" and St.join.slots or {}
    for cid, seat in pairs(t) do
        cid, seat = tonumber(cid), tonumber(seat)
        if cid and seat and cid ~= id and r.of[cid] == nil and not r.sat[cid] and r.at[seat] == nil
            and slots[cid] ~= nil then
            out[seat] = cid
        end
    end
    return out
end

-- a seat for ctrlId: the one it holds, else the seat its pad held last time (PAD MEMORY) when free, else `prefer`, else
-- the lowest free seat - a seat remembered for another pad that is here comes last. nil when every seat is taken.
function M.claim(ctrlId, why, prefer)
    local id = tonumber(ctrlId)
    if id == nil or id < 1 then return nil end
    local r = reg()
    if r.of[id] ~= nil then return r.of[id] end
    local CR = mem()
    local s, how = nil, nil
    local okM, last = false, nil
    if CR then okM, last = pcall(CR.padSeatOf, id) end
    last = okM and tonumber(last) or nil
    if last and last >= FIRST and last <= LAST and r.at[last] == nil then
        s, how = last, "the seat this pad sat in last time"
    else
        local res = CR and reservedFor(r, id, CR) or {}
        s = freeSeat(r, prefer, res)
        if s == nil then s = freeSeat(r, prefer) end
        if s ~= nil and next(res) ~= nil then
            local t = {}
            for seat, cid in pairs(res) do t[#t + 1] = string.format("seat %d kept for ctrlId %d", seat, cid) end
            table.sort(t)
            how = "pad memory: " .. table.concat(t, ", ")
        end
        if last and s ~= last then
            how = string.format("%sits seat %d of last time is taken", how and (how .. "; ") or "", last)
        end
    end
    if s == nil then
        U.logEvery("couchseat.full" .. id, 10000, TAG, "WARN ctrlId %d: every seat (%d-%d) is taken, no seat", id, FIRST, LAST)
        return nil
    end
    set(r, id, s)
    U.log(TAG, "ctrlId %d sits down in seat %d (P%d's progress) (%s%s)", id, s, s, tostring(why),
        how and ("; " .. how) or "")
    return s
end

-- A pad JOINS (join.lua's join press). gone(holderCtrlId) -> true when that seat's holder is joined with his pad
-- disconnected: his seat is the one a pad swap continues. -> seat, displaced ctrlId (the old holder of a taken-over
-- seat, to be un-joined by the caller) | nil
function M.join(ctrlId, why, gone)
    local id = tonumber(ctrlId)
    if id == nil or id < 1 then return nil end
    local r = reg()
    if r.of[id] ~= nil then
        U.log(TAG, "ctrlId %d joins: keeps seat %d (%s)", id, r.of[id], tostring(why))
        return r.of[id], nil
    end
    if type(gone) == "function" then
        for s = FIRST, LAST do
            local h = r.at[s]
            if h ~= nil and h ~= id then
                local ok, g = pcall(gone, h)
                if ok and g == true then
                    r.of[h] = nil
                    set(r, id, s)
                    U.log(TAG, "ctrlId %d joins into seat %d: a pad swap (seat %d's pad, ctrlId %d, is disconnected): "
                        .. "the seat and its progress go on with the new pad (%s)", id, s, s, h, tostring(why))
                    return s, h
                end
            end
        end
    end
    return M.claim(id, why), nil
end

-- A guest LEAVES (hold B / lobby B / F7 / un-joined): his seat is free; its progress stays saved for the run.
function M.leave(ctrlId, why)
    local id = tonumber(ctrlId)
    if id == nil then return nil end
    local r = reg()
    local s = r.of[id]
    if s == nil then return nil end
    r.of[id] = nil
    if r.at[s] == id then r.at[s] = nil end
    U.log(TAG, "ctrlId %d leaves seat %d (%s): the seat is free, its progress is kept for a rejoin", id, s, tostring(why))
    return s
end

-- The joined set (join.joinedList, every call): joined = { {ctrlId, pnum}, ... } in view order. A seat whose holder
-- is no longer joined is freed (an un-join join.lua did not report); a joined ctrlId without a seat gets one
-- (preferring its pnum). -> nothing
function M.reconcile(joined, why)
    local r = reg()
    local here = {}
    for _, e in ipairs(joined or {}) do
        local id = tonumber(e.ctrlId)
        if id then here[id] = true end
    end
    for id, s in pairs(r.of) do
        if not here[id] then
            r.of[id] = nil
            if r.at[s] == id then r.at[s] = nil end
            U.log(TAG, "ctrlId %d is no longer joined: seat %d free (%s), its progress is kept", id, s, tostring(why or "sync"))
        end
    end
    for _, e in ipairs(joined or {}) do
        local id = tonumber(e.ctrlId)
        if id and r.of[id] == nil then M.claim(id, why or "joined", e.pnum) end
    end
end

-- The storage key of a guest's progress: his seat. A ctrlId without one claims one (preferring pnum) unless join.lua
-- knows it as NOT joined (a dormant guest has no seat: nil). P1 (0) / invalid -> nil.
function M.key(ctrlId, pnum)
    local id = tonumber(ctrlId)
    if id == nil or id < 1 then return nil end
    local s = reg().of[id]
    if s ~= nil then return s end
    local slot = type(St.join.slots) == "table" and St.join.slots[id] or nil
    if type(slot) == "table" and slot.joined ~= true then return nil end
    return M.claim(id, "first use of his progress", pnum)
end

-- The seat of the joined guest SHOWN as P<pnum> now (garage.lua's per-seat records, whose callers hold a pnum). P1 = 1;
-- no joined guest with that number -> pnum itself.
function M.ofPnum(pnum)
    local n = tonumber(pnum)
    if n == nil then return nil end
    if n == 1 then return 1 end
    local okJ, list = pcall(function() return U.mod("join").joinedList() end)
    if okJ and type(list) == "table" then
        for _, e in ipairs(list) do
            if tonumber(e.pnum) == n then
                return tonumber(e.seat) or M.key(e.ctrlId, e.pnum) or n
            end
        end
    end
    return n
end

-- "P2" or "P2 (seat 3)"
function M.label(pnum, seat)
    if seat == nil or tonumber(seat) == tonumber(pnum) then return "P" .. tostring(pnum) end
    return string.format("P%s (seat %s)", tostring(pnum), tostring(seat))
end

-- hot reload (join.persistShared / restoreShared): "1:2,2:3"
function M.encode()
    local t = {}
    for id, s in pairs(reg().of) do t[#t + 1] = string.format("%d:%d", id, s) end
    table.sort(t)
    return table.concat(t, ",")
end
function M.decode(v)
    if type(v) ~= "string" or v == "" then return 0 end
    local r = reg()
    local n = 0
    for idStr, sStr in v:gmatch("(%d+):(%d+)") do
        local id, s = tonumber(idStr), tonumber(sStr)
        if id >= 1 and s >= FIRST and s <= LAST and r.at[s] == nil then set(r, id, s); n = n + 1 end
    end
    return n
end

function M.status()
    local e = M.encode()
    return "couchseat: " .. (e ~= "" and e or "no seat taken")
end

function M._reset() St.join = St.join or {}; St.join.seats = nil end   -- tests / sim: a new game process

return M
