-- padmap.lua (couch-fix72, player report #13 "Reassign Controllers"): which PHYSICAL pad each local player holds when
-- it is not the pad the mod knows him by.
--
-- WHY. A pad's ControllerId is its enumeration slot (XInput / SDL: UE maps device k+1 -> platform user k -> Slate user
-- k -> ControllerId k; join.lua device hook logs, every session: "state=3 user=k device=k+1"). After a disconnect /
-- reconnect the OS can hand the two pads each other's slots (player report #7: "P1 and P2 can suddenly swap
-- controllers"): P1's physical pad then drives P2's car and the other way round, and nothing in the game tells which
-- pad is whose (the ControllerId is the only pad identity Lua gets, couchseat.lua header). REASSIGN CONTROLLERS
-- (reassign.lua, the race pause menu) asks each player to press A on his pad and moves the ControllerIds so that each
-- local player's PlayerController hears the pad that player holds.
--
-- TWO IDS PER PLAYER from then on:
--   ident  the id the mod KNOWS him by: P1 = 0, a guest = the id he joined with. join.lua's slots, couchseat's seats,
--          couchrun's / couchbets' / couchbacker's per-player records are keyed by it. NEVER changes here: P2's seat,
--          credits, build and progress stay P2's whatever pad he holds ("progress follows the seat, not the pad").
--   pad    the live ControllerId his LocalPlayer carries in the normal state (no couch shared-screen swap / park /
--          garage turn): the pad he holds. The native input filter (inputfix: the live id), Enhanced Input (the engine:
--          the live id) and the DLL's pad watch (Slate user = pad id) all follow it.
-- Without a reassignment (the default, and after one that changed nothing) the map is EMPTY and ident == pad == the
-- live id for everybody: every caller below then behaves exactly as before couch-fix72.
--
-- Entries are keyed by the LocalPlayer object (ULocalPlayer and its ControllerId live as long as the game process: the
-- PlayerControllers are new in every world, the LocalPlayers are not). A LocalPlayer that is gone drops its entry; a
-- LocalPlayer without an entry (a guest who joined after the reassignment) is ident = pad = its live id.
-- Hot reload: encode / decode by LocalPlayer index (reassign.persistShared).
local St = require("state")
local U = require("util")

local M = {}
local TAG = "padmap"

local function R()
    local r = St.padmap
    if type(r) ~= "table" or type(r.list) ~= "table" then
        r = { list = {}, sets = 0 }
        St.padmap = r
    end
    return r
end

local function lps()
    local ok, l = pcall(U.localPlayersRO)
    return (ok and type(l) == "table") and l or {}
end

-- the entry of a local player (live list entry {lp, pc, ctrlId, index}), nil when it has none
local function entryOf(e)
    if type(e) ~= "table" then return nil end
    local k = U.key(e.lp)
    if k == 0 then return nil end
    return R().list[k]
end

-- entries whose LocalPlayer is no longer in GameInstance.LocalPlayers are dropped (cheap: called by the lookups below)
local function prune()
    local r = R()
    if next(r.list) == nil then return r end
    local here = {}
    for _, e in ipairs(lps()) do
        local k = U.key(e.lp)
        if k ~= 0 then here[k] = e.index end
    end
    if next(here) == nil then return r end              -- no local player readable (a travel frame): keep the map
    for k, v in pairs(r.list) do
        if here[k] == nil then
            r.list[k] = nil
            U.log(TAG, "local player %s (ident %s, pad %s) is gone: its pad entry dropped", tostring(v.index),
                tostring(v.ident), tostring(v.pad))
        else
            v.index = here[k]
        end
    end
    return r
end

--- true while at least one local player holds another pad than the one he is known by
function M.active()
    return next(prune().list) ~= nil
end

--- the ident of a live local-player entry ({lp, ...}); fallback = its live ctrlId
function M.identOf(e)
    local x = entryOf(e)
    if x then return x.ident end
    return type(e) == "table" and e.ctrlId or nil
end

--- the pad (normal live id) of a live local-player entry; nil = no entry (it keeps its own live id)
function M.padOfEntry(e)
    local x = entryOf(e)
    return x and x.pad or nil
end

--- ident -> the pad that player holds (the ident itself when the map does not move him)
function M.padOfIdent(id)
    if id == nil then return nil end
    for _, x in pairs(prune().list) do
        if x.ident == id then return x.pad end
    end
    return id
end

--- pad id -> the ident of the player holding it (the pad id itself when no entry names it)
function M.identOfPad(pad)
    if pad == nil then return nil end
    for _, x in pairs(prune().list) do
        if x.pad == pad then return x.ident end
    end
    return pad
end

--- P1's physical pad id (0 unless the map moved him): "the holder of pad id 0 = P1's pad" sites ask this instead of 0
function M.p1Pad()
    local l = lps()
    local e = l[1]
    if e then
        local x = entryOf(e)
        if x and type(x.pad) == "number" then return x.pad end
    end
    return 0
end

--- The normal ids of the local players: {[pcKey] = pad}, every local player with a PC. Entries give their pad; a player
--- without one keeps his live id when that is a plain pad id (< park) nobody else's normal id takes, else the lowest
--- free one. nil when the map is empty (the caller's own normalisation applies). parkId = couch.PARK_ID.
function M.normalIds(liveIds, parkId)
    local r = prune()
    if next(r.list) == nil then return nil end
    parkId = tonumber(parkId) or 6
    local want, used, rest = {}, {}, {}
    for _, e in ipairs(lps()) do
        if U.ok(e.pc) then
            local k = U.key(e.pc)
            local x = entryOf(e)
            if x and type(x.pad) == "number" then
                want[k], used[x.pad] = x.pad, true
            else
                rest[#rest + 1] = { k = k, id = type(liveIds) == "table" and liveIds[k] or e.ctrlId }
            end
        end
    end
    for _, q in ipairs(rest) do
        local id = tonumber(q.id)
        if id == nil or id < 0 or id >= parkId or used[id] then
            id = 0
            while used[id] do id = id + 1 end
        end
        want[q.k], used[id] = id, true
    end
    return want
end

--- Sets the map: list = { {lp = LocalPlayer, ident = n, pad = n, index = i}, ... }. Entries with ident == pad are not
--- stored (that player holds his own pad); every previous entry is replaced. -> number of moved players
function M.set(list, why)
    local r = R()
    r.list = {}
    local n, parts = 0, {}
    for _, v in ipairs(list or {}) do
        local k = U.key(v.lp)
        if k ~= 0 and type(v.ident) == "number" and type(v.pad) == "number" and v.ident ~= v.pad then
            r.list[k] = { ident = v.ident, pad = v.pad, index = v.index }
            n = n + 1
            parts[#parts + 1] = string.format("P%s (ident %d) on pad id %d", tostring(v.index), v.ident, v.pad)
        end
    end
    r.sets = (r.sets or 0) + 1
    if n > 0 then
        U.log(TAG, "pad map set (%s): %s (V-RA-04)", tostring(why), table.concat(parts, ", "))
    else
        U.log(TAG, "pad map cleared (%s): every local player holds the pad he is known by (V-RA-04)", tostring(why))
    end
    return n
end

function M.clear(why)
    local r = R()
    if next(r.list) == nil then return false end
    r.list = {}
    U.log(TAG, "pad map cleared (%s) (V-RA-04)", tostring(why))
    return true
end

--- "P1 (ident 0) pad 1, P2 (ident 1) pad 0" | "empty" (diag / logs)
function M.describe()
    local t = {}
    for _, x in pairs(prune().list) do
        t[#t + 1] = string.format("P%s ident %s pad %s", tostring(x.index), tostring(x.ident), tostring(x.pad))
    end
    table.sort(t)
    return #t > 0 and table.concat(t, ", ") or "empty"
end

--- hot reload: "index:ident:pad,..." (LocalPlayer index in GameInstance.LocalPlayers order)
function M.encode()
    local t = {}
    for _, x in pairs(prune().list) do
        t[#t + 1] = string.format("%d:%d:%d", tonumber(x.index) or 0, x.ident, x.pad)
    end
    table.sort(t)
    return table.concat(t, ",")
end

--- the inverse of encode, against the live local players (game thread). -> entries restored
function M.decode(v)
    if type(v) ~= "string" or v == "" then return 0 end
    local byIndex = {}
    for _, e in ipairs(lps()) do byIndex[e.index] = e end
    local list = {}
    for i, a, b in v:gmatch("(%d+):(%d+):(%d+)") do
        local e = byIndex[tonumber(i)]
        if e then list[#list + 1] = { lp = e.lp, index = e.index, ident = tonumber(a), pad = tonumber(b) } end
    end
    if #list == 0 then return 0 end
    return M.set(list, "hot reload")
end

function M._reset() St.padmap = nil end           -- tests / sim

return M
