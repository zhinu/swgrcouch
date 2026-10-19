-- SWGRCouch · roster.lua (G6 Racer assignment)
-- Who is human, local or remote, and since when (ARCHITECTURE §4.2 G6 roster, §3.1 gate 4).
-- Everything is computed on demand from owners the engine prunes (GameInstance.LocalPlayers,
-- GameState.PlayerArray); only arrival times and mid-game-joiner flags are stored (St.roster).
--
-- Verified signatures (scripts/reflect-func-all.py on the shipping exe):
--   AController:IsLocalController() -> Bool                      (0x54020402)
--   AActor:GetOwner() -> Object                                    (0x54020401)
--   APlayerState:GetPlayerName() -> Str                            (0x54020403)
--   GameModeBase:HandleStartingNewPlayer(Object NewPlayer)         (0x8020c02, BlueprintNativeEvent, hookable)
--   PlayerSpectatorComponent:Client_SetIsMidGameJoiner(Bool isMidGameJoiner)  (0x1040cc1, NetClient RPC)
-- Properties: AGameStateBase.PlayerArray, AActor.Owner, AController.PlayerState, APlayerState.bIsABot (Bool),
--   AGfnPlayerController.SpectatorComponent @+0x898, UPlayerSpectatorComponent.bIsMidGameJoiner (Bool).

local C   = require("consts")
local St  = require("state")
local U   = require("util")

local M = {}
local TAG = "roster"

-- freshWorld: set by the "world" listener (and true at load: a hot reload may keep St.worldKey and fire no
-- "world"), consumed by the next tick; only PCs without a kept firstSeen stamp are affected (scalars only).
local priv = { freshWorld = true }

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------

local function nameOf(pc)
    local name = "?"
    U.try(TAG, function()
        local ps = pc.PlayerState
        if U.ok(ps) then
            name = U.str(ps:GetPlayerName())          -- APlayerState::GetPlayerName() -> FString
        end
        if (name == "" or name == "?") and U.ok(pc) then
            name = U.str(pc:GetFName())
        end
    end)
    return name
end

local function isLocal(pc)
    local ok, res = pcall(U.callMethod, pc, "IsLocalController")
    return ok and res == true
end

-- A local guest PC that is only a dormant lobby slot (not joined) or that is leaving is not a human racer.
local function isDormantOrLeaving(ctrlId)
    local slots = St.join and St.join.slots
    if type(slots) ~= "table" then return false end
    local s = slots[ctrlId]
    if type(s) ~= "table" then return false end
    if s.leaving == true then return true end
    return St.join.active == true and s.joined ~= true
end

-- ---------------------------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------------------------

-- Every valid local PlayerController, P1 first (U.localPlayers is sorted by index).
function M.localPCs()
    local out = {}
    local lps = U.localPlayers()
    for _, e in ipairs(lps) do                         -- Lua array from util, not a TArray
        if U.ok(e.pc) then out[#out + 1] = e.pc end
    end
    return out
end

-- Server: remote PlayerControllers (incl. child connections of split-screen clients).
-- Client: PlayerStates of remote humans.
function M.remoteHumans()
    local out = {}
    local gs = U.gs()
    if not U.ok(gs) then return out end
    local arr = gs.PlayerArray                         -- TArray<APlayerState*>
    local okc, n = pcall(U.arrayCount, arr)
    if not okc or type(n) ~= "number" then return out end
    if U.isServer() then
        local seen = {}
        for i = 1, n do                                -- numeric loop only: reading past the end grows a TArray
            U.try(TAG, function()
                local ps = arr[i]
                if not U.ok(ps) then return end
                local o = ps.Owner                      -- AActor.Owner
                if U.isPlayerController(o) and not isLocal(o) then
                    local k = U.key(o)
                    -- an adopted racer PS (§3.3) is also owned by the human PC: de-duplicate by PC address
                    if k ~= 0 and not seen[k] then
                        seen[k] = true
                        out[#out + 1] = o
                    end
                end
            end)
        end
    else
        local localPS, localPC = {}, {}
        for _, pc in ipairs(M.localPCs()) do
            localPC[U.key(pc)] = true
            local ps = pc.PlayerState
            if U.ok(ps) then localPS[U.key(ps)] = true end
        end
        for i = 1, n do
            U.try(TAG, function()
                local ps = arr[i]
                if not U.ok(ps) then return end
                if ps.bIsABot ~= false then return end  -- Bool property; bots and unreadable entries skipped
                if localPS[U.key(ps)] then return end
                -- a local guest's own PS left behind by a (remote-side) adoption is still owned by that local PC
                local o = ps.Owner
                if U.ok(o) and localPC[U.key(o)] then return end
                out[#out + 1] = ps
            end)
        end
    end
    return out
end

-- Server only (on a client this returns the local human PCs, the only PCs that exist there):
-- local joined players + remote PCs, de-duplicated, local first.
function M.humanPCs()
    local out, seen = {}, {}
    for _, e in ipairs(U.localPlayers()) do
        local pc = e.pc
        -- P1 (ControllerId 0) never has a join slot, so it is never filtered out
        if U.ok(pc) and not isDormantOrLeaving(e.ctrlId) then
            local k = U.key(pc)
            if k ~= 0 and not seen[k] then seen[k] = true; out[#out + 1] = pc end
        end
    end
    if U.isServer() then
        for _, pc in ipairs(M.remoteHumans()) do
            local k = U.key(pc)
            if k ~= 0 and not seen[k] then seen[k] = true; out[#out + 1] = pc end
        end
    end
    return out
end

-- Map PlayerState address -> {pnum, colour, isLocal} for name tags (nametags.lua).
-- Local players: their own PS and, with a takeover record, the racer PS they drive (takeover.racerPSFor).
-- Remote humans: server -> the PC's PlayerState (+ racer PS); client -> the PS itself.
function M.humanPlayerStates()
    local map = {}
    local function put(ps, entry)
        if U.ok(ps) then
            local k = U.key(ps)
            if k ~= 0 then map[k] = entry end
        end
    end
    local takeover = U.mod("takeover")
    local join = U.mod("join")
    for _, e in ipairs(U.localPlayers()) do
        local pc = e.pc
        if U.ok(pc) and not isDormantOrLeaving(e.ctrlId) then
            U.try(TAG, function()
                local pnum = nil
                local okp, p = pcall(join.pnumForPC, pc)
                if okp and type(p) == "number" then pnum = p end
                local entry = { pnum = pnum, colour = (pnum and C.COLOURS[pnum]) or C.COLOURS.Remote, isLocal = true }
                put(pc.PlayerState, entry)
                put(takeover.racerPSFor(pc), entry)
            end)
        end
    end
    local remoteEntry = { pnum = nil, colour = C.COLOURS.Remote, isLocal = false }
    if U.isServer() then
        for _, pc in ipairs(M.remoteHumans()) do
            U.try(TAG, function()
                put(pc.PlayerState, remoteEntry)
                put(takeover.racerPSFor(pc), remoteEntry)
            end)
        end
    else
        for _, ps in ipairs(M.remoteHumans()) do put(ps, remoteEntry) end
    end
    return map
end

-- St.nowMs() of the first time this PC was seen in the current world, or nil.
function M.firstSeenMs(pc)
    if not U.ok(pc) then return nil end
    return St.roster.firstSeen[U.key(pc)]
end

-- VERIFY(V-TKO-09): Client_SetIsMidGameJoiner is a NetClient RPC: our post-hook only fires where it executes
-- (owning client, or the listen host for its own local PCs). For a remote PC on the server only the
-- bIsMidGameJoiner property can tell, and it may never be set server-side; the firstSeen rule in
-- takeover (gate 4) is the fallback that always works.
function M.isMidGameJoiner(pc)
    if not U.ok(pc) then return false end
    if St.roster.midGame[U.key(pc)] == true then return true end
    local mid = false
    pcall(function()
        local sc = pc.SpectatorComponent               -- AGfnPlayerController.SpectatorComponent @+0x898
        if U.ok(sc) and sc.bIsMidGameJoiner == true then mid = true end
    end)
    return mid
end

-- Record the arrival time of a PC once per world. atMs (optional) backdates it (see M.tick).
function M.noteArrival(pc, atMs)
    if not U.ok(pc) then return end
    local k = U.key(pc)
    if k == 0 or St.roster.firstSeen[k] ~= nil then return end
    St.roster.firstSeen[k] = atMs or St.nowMs()
    local loc = isLocal(pc)
    U.log(TAG, "arrival: %s (%s) at %.0f ms%s, phase %s, race started %s",
        nameOf(pc), loc and "local" or "remote", St.roster.firstSeen[k], atMs and " (backdated)" or "",
        tostring(St.phase), tostring(St.race.started))
end

-- MAIN poll in a race; also called by net.tick() in the front end while hosting.
function M.tick()
    local pcs = M.humanPCs()
    local present = {}
    -- First tick of a new world that phase.tick already saw RACING/POSTRACE (hot reload mid-race, race world first
    -- detected after its start): in the same mainTick phase.tick emitted "world" (firstSeen wiped) and then stamped
    -- St.race.startedAtMs, so stamping "now" would make every carless human fail takeover gate 4 ("joined after the
    -- start"). PCs already present then are recorded as arrived just before the start. Real late joiners still get
    -- their true time from the HandleStartingNewPlayer post-hook (noteArrival keeps the first stamp).
    -- VERIFY(V-TKO-09): a remote PC that connected after the start but before this first tick (only possible across
    -- a hot reload, which loses the hook stamp) is treated as pre-start; isMidGameJoiner still filters it.
    local backdate = nil
    if priv.freshWorld then
        priv.freshWorld = false
        local t = St.race.startedAtMs
        if St.race.started == true and type(t) == "number" and t > 0 then backdate = t - 1 end
    end
    local humans, remote = {}, {}
    for _, pc in ipairs(pcs) do
        U.try(TAG, function()
            local k = U.key(pc)
            if k == 0 then return end
            present[k] = true
            M.noteArrival(pc, backdate)
            local loc = isLocal(pc)
            humans[k] = { kind = loc and "local" or "remote", name = nameOf(pc) }
            if not loc then remote[k] = true end
        end)
    end
    -- Forget PCs that are gone: a later PC allocated at the same address must not inherit an old
    -- (pre-start) arrival time, or a mid-game joiner would pass takeover gate 4.
    for k in pairs(St.roster.firstSeen) do
        if not present[k] then St.roster.firstSeen[k] = nil end
    end
    St.roster.humans = humans
    St.roster.remote = remote
end

-- ---------------------------------------------------------------------------------------------
-- hooks and listeners
-- ---------------------------------------------------------------------------------------------

local function onStartingNewPlayer(ctx, NewPlayer)
    local pc = NewPlayer:get()
    if not U.ok(pc) then return end
    -- VERIFY(V-NET-10): reached only after login passed; one line per remote PC (child connections included)
    U.log(TAG, "HandleStartingNewPlayer: %s local=%s netmode=%s phase=%s",
        U.str(pc:GetFName()), tostring(isLocal(pc)), U.netMode(), tostring(St.phase))
    M.noteArrival(pc)
end

local function onMidGameJoiner(ctx, isMid)
    local comp = ctx:get()
    if not U.ok(comp) then return end
    local owner = comp:GetOwner()                      -- ActorComponent:GetOwner() -> AActor (the PC)
    if not U.ok(owner) then return end
    local v = isMid:get() == true
    St.roster.midGame[U.key(owner)] = v
    U.log(TAG, "Client_SetIsMidGameJoiner(%s) for %s", tostring(v), U.str(owner:GetFName()))
end

function M.init()
    U.hook(C.FN.StartingNewPlayer, { post = onStartingNewPlayer }, TAG)
    U.hook(C.FN.MidGameJoiner, { post = onMidGameJoiner }, TAG)
    St.on("world", TAG, function()
        priv.freshWorld = true
        St.roster.firstSeen = {}
        St.roster.midGame = {}
        St.roster.humans = {}
        St.roster.remote = {}
    end)
end

return M
