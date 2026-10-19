-- instances.lua: COUCH MISSION INSTANCES (couch-trial2, finding #30 redesign, Jules 2026-10-17: "both race on the same
-- race in the same map but as if we were playing two separate games. So race of P1 and race of P2 are not the same
-- (even though it is the same start setup)").
--
-- A single-player mission (first: the planet's PLANE TEST = PODRACER TEST, CampaignRun:KickOffPlaneTestEvent) gives
-- EVERY human his own copy of the mission's field: P1 + the named opponents (Tatooine: Teemto, Dud Bolt, Ody,
-- Gasgano, Ben Quadinaros) + any AI fill, and for each guest a second (third) copy of the same field. One race world,
-- N "sets" (instances); each human sees and touches only his own set.
--
-- REFLECTION FACTS (JMAP Griffin-5.7.4-381121, tools: scripts/decode/jmapq.py) this module relies on:
--   [V] APlayerController.HiddenActors +0x3b8 TArray<AActor*> (UPROPERTY): ULocalPlayer::CalcSceneView ->
--       PlayerController::BuildHiddenComponentList hides every primitive of these actors in THAT player's view only
--       (engine source; the split views are one LocalPlayer each). Written by appending one past the end (UE4SS grows
--       a TArray written at Num + 1: live 2026-10-15, AppliedAffixes) and :Empty() (live: RecipeState.Racers).
--   [V] UPrimitiveComponent:IgnoreActorWhenMoving(Actor, bShouldIgnore) (MoveIgnoreActors +0x358), AActor:
--       K2_GetRootComponent, GetCollisionObjectType / GetCollisionProfileName (logged for the live check).
--   [V] RaceEventDef.GridMakeup (RaceGridMakeup.Entries[] = {EntryType, NumEntrants Byte}), .CustomOpponents
--       (TArray<RaceEventCustomRacer> STRUCTS: not duplicated from Lua - the builder's own fill entries are grown and
--       re-dressed as the opponents instead), EventRecipeState.Racers[] = RecipeRacerSetup {Player, Pilot,
--       vehicleType, VehicleCustomisation} (0x18..0x80 not reflected: the AI build state there is NOT copied).
--   [V] GfnPlayerState.Pilot / RacerStyle / RacerBuildState, PlayerRaceEventComponent.EventPosition / FailReasons /
--       bHasFinishedEvent / EventFinishTime, RacingGameState.Vehicles[] (VehiclePawn), APawn.PlayerState.
--   [?] the race spawn keeps RecipeState.Racers order and its Player refs in the race world (the sim's spawn model;
--       the live crash of 2026-10-14 read a stale AI PlayerState there = the spawn does read them)
--   [L] PHYSICS (tester #3, 2026-10-18, #59): MoveIgnoreActors only filters SWEEPS - the sets' cars still bumped (P1's
--       AI car took P2's invisible bots down 22-30 times a race). The car's physics body is its root CustomisationRoot
--       (live: object type 6 = ECC_Vehicle, profile "Vehicle"; the game itself switches it to Vehicle_Crashing /
--       Vehicle_NoBattling = the game's car-vs-car contacts ARE the collision responses: NoBattling = ignore Vehicle).
--   [V] the game's channels (Default__CollisionProfile in the JMAP): ECC_GameTraceChannel1..7 (14..20) = Trigger,
--       NonCrashingWorldStatic, AudioOcclusion, CrashingOnlyWorldStatic, Repulsable, GeometryTracing, Crashing;
--       GameTraceChannel8.. (21..) are unused = every profile answers them with the default Block (every physics
--       profile answers Vehicle Block too; Trigger-type volumes still overlap: the car answers Trigger Overlap).
--   => cfg.CouchInstancesCollision "channels" (M.separate): guest set s (2..4) = object type 21 + s - 2; each of its
--       Vehicle-type primitives gets its own channel answered as it answered Vehicle (contacts inside the set as the
--       game's, NoBattling included), Vehicle and the later sets' channels Ignore. A Chaos contact needs BOTH shapes
--       to block the other's type: set 1 (P1, untouched) x set s is filtered by set s's Ignore, set s x set t (s < t)
--       by set s's. Re-asserted every 100 ms (M.fastTick) after the game's own profile switch puts type 6 back.
--   [?] live: no cross-set bump ("NOT counted: a bot of another player's instance" gone), P2's own takedowns still
--       count, P2's cars still pass the checkpoints / boost pads / gates. Native object-type queries for "Vehicle"
--       (if the game has any: AI avoidance, AOE) see set 1 only.
--   [?] EventPosition is ranked natively over ALL racers: the set's own place is re-ranked here (the order inside one
--       set is the order of the global ranking), shown on the HUD (hud.lua) and used for the booking (couchrules D3).
-- Every game access is pcall-guarded; UObjects are held only inside one race world (dropped on "leaving" / "world").
local U = require("util")
local St = require("state")
local cfg = require("config")

local TAG = "instances"
local M = {}

local function opt(k, d) local v = cfg[k]; if v == nil then return d end; return v end
local FAIL_TARGET = 2 + 8         -- REC.FailReasons ModeRules | ExtraConditions (target missed), as couchrun

-- plan = plain data from the kickoff (survives the travel): {S = set size, nG = guests, pnums = {[g] = pnum}, n}
-- race = this world's sets (UObjects, dropped with the world)
local plan = nil
local race = nil
local stats = { assigned = 0, fallbacks = 0 }

function M.enabled() return opt("CouchMissionInstances", true) == true end
function M.planned() return plan ~= nil end
function M.plan() return plan end
function M.active() return race ~= nil and race.ok == true end
function M.stats() return stats end

function M.reset(why)
    if plan or race then U.log(TAG, "instances off (%s)", tostring(why)) end
    plan, race = nil, nil
end

---------------------------------------------------------------------------------------------------- kickoff (paddock)
-- couch.planeTestPre / couch.fieldTestPre ask: the grid an event needs for N instances. -> want, S (nil = no instances:
-- the shared field, the humans ghosted), why, fullS (the set size the event wants = solo's field: S < fullS when the
-- cap shrank the sets). opts (all optional): cap (default cfg.CouchInstancesMaxGrid), capKey (its name in the log),
-- shrink (more players than fit: each set as large as fits, >= 2 cars, instead of no instances)
function M.gridFor(total, opp, nG, name, opts)
    opts = opts or {}
    if not M.enabled() then return nil, nil, "CouchMissionInstances off" end
    local S = math.max(total, 1 + opp)
    local want = S * (1 + nG)
    local capKey = opts.capKey or "CouchInstancesMaxGrid"
    local cap = math.floor(tonumber(opts.cap or opt("CouchInstancesMaxGrid", 12)) or 12)
    if want > cap then
        local S2 = math.floor(cap / (1 + nG))
        if opts.shrink and S2 >= 2 then
            return S2 * (1 + nG), S2, string.format("%s: %d instance(s) x %d = %d racers > %s %d: each set %d car(s) "
                .. "(P + %d of the %d opponents)", tostring(name), 1 + nG, S, want, capKey, cap, S2, S2 - 1, S - 1), S
        end
        return nil, S, string.format("%s: %d instance(s) x %d = %d racers > %s %d", tostring(name),
            1 + nG, S, want, capKey, cap), S
    end
    return want, S, nil, S
end

-- Q8 B (Jules 2026-10-18, audit issue 15): a takedown target made for solo's field (P + 7 bots) raced in a SMALLER set
-- (the grid cap, or the game's builder clamping the grid) is scaled to the set's opponents: target x (S - 1) /
-- (fullS - 1), rounded up, at least 1. -> scaled target (the target itself when the set is full)
function M.scaleTarget(target, S, fullS)
    target, S, fullS = tonumber(target), tonumber(S), tonumber(fullS)
    if not (target and S and fullS) or fullS <= 1 or S >= fullS or target <= 0 then return target end
    return math.max(1, math.ceil(target * (S - 1) / (fullS - 1) - 1e-9))
end

-- this race's sets smaller than the event's field? -> S, fullS, players (nil when the sets are full / no plan)
function M.shrunk()
    if not (plan and plan.fullS and plan.S and plan.S < plan.fullS) then return nil end
    return plan.S, plan.fullS, 1 + (plan.nG or 0)
end

local function nameOf(o)
    local n = "?"
    if U.ok(o) then pcall(function() n = o:GetFName():ToString() end) end
    return n
end
local function psName(ps)
    local n = "?"
    pcall(function() n = ps:GetPlayerName():ToString() end)
    return n
end

-- the kickoff's post-hook (couch.planeTestPost): the builder made S x (1 + nG) entries [P1, opponents..., fill...]; set
-- g (1..nG) = entries S*g+1 .. S*(g+1): its first entry goes to guest g (P1's pod + mission pilot), the others are
-- dressed as set 0's entry of the same rank (pilot, class, pod; the bot's PlayerState pilot / style / build state).
-- -> placed guests, or nil + why (the caller falls back to couch.patchGrid)
-- opts (optional): adapt (a grid the builder clamped to a multiple of the players: smaller sets, WARN), kind / ev (the
-- event's kind and name: logs, couchsolo / soloscore)
function M.assignGrid(racers, guests, S, p1ps, opts)
    opts = opts or {}
    local fullS = tonumber(opts.fullS) or S          -- Q8: the event's own set size (solo's field), before any shrink
    local n = U.arrayCount(racers)
    local nG = #guests
    if n ~= S * (1 + nG) then
        local S2 = n // (1 + nG)
        if opts.adapt and n > 1 + nG and n % (1 + nG) == 0 and S2 >= 2 and S2 < S then
            U.warn(TAG, "kickoff: the builder made %d racer(s), not %d x %d = %d (the game's grid limit?): each set %d "
                .. "car(s) (P + %d opponent(s))", n, 1 + nG, S, S * (1 + nG), S2, S2 - 1)
            S = S2
        else
            return nil, string.format("grid of %d, want %d (%d x %d): the builder did not grow it", n, S * (1 + nG),
                1 + nG, S)
        end
    end
    local first = nil
    pcall(function() first = racers[1].Player end)
    if not (U.ok(first) and U.ok(p1ps) and U.key(first) == U.key(p1ps)) then
        return nil, "entry 1 is not P1's (" .. psName(first) .. ")"
    end
    local p1e = racers[1]
    local pnums, notes = {}, {}
    local swaps = {}
    for g, gu in ipairs(guests) do
        local base = S * g
        -- live 2026-10-18 (tester #3, Ando Prime takedowns): the all-PC builder puts EVERY player on the grid first
        -- (entry 2 = P2), so writing the guest into his set's first entry left him TWICE in the recipe: one car less
        -- (GameState.Vehicles 15 of 16), his own car in set 1 = hidden in his OWN view, set 1 one opponent short and a
        -- bot in set 2 dressed as the guest's builder entry. His builder entry takes the bot that his set's first
        -- entry held (player, pilot, vehicle) before he is written there. A pre-pass: the sets copy set 1's opponents
        -- only after every guest has left set 1 (3P: P3's builder entry 3 is in set 1 too).
        local okS, errS = pcall(function()
            local gk = U.key(gu.ps)
            for i = 1, n do
                if i ~= base + 1 then
                    local ps = nil
                    pcall(function() ps = racers[i].Player end)
                    if U.ok(ps) and U.key(ps) == gk then
                        local d, b = racers[i], racers[base + 1]
                        local bp, bpil, bvt, bvc = b.Player, b.Pilot, b.VehicleType, b.VehicleCustomisation
                        d.Player = bp
                        d.Pilot = bpil
                        d.VehicleType = bvt
                        d.VehicleCustomisation = bvc
                        swaps[#swaps + 1] = string.format("P%d's builder entry %d <- entry %d's bot", gu.pnum, i,
                            base + 1)
                        break
                    end
                end
            end
        end)
        if not okS then return nil, "guest " .. tostring(gu.pnum) .. "'s builder entry: " .. tostring(errS) end
    end
    for g, gu in ipairs(guests) do
        local base = S * g
        local okH, errH = pcall(function()
            local e = racers[base + 1]
            e.Player = gu.ps
            e.VehicleType = p1e.VehicleType
            e.VehicleCustomisation = p1e.VehicleCustomisation
            -- a mission (plane test) is the mission's character for everyone; a field test keeps the guest his own pilot
            -- (opts.guestPilot = "own": his entry keeps the builder's, his PlayerState is not touched)
            local pil = p1e.Pilot
            if U.ok(pil) and opts.guestPilot ~= "own" then
                e.Pilot = pil
                pcall(function() gu.ps.Pilot = pil end)
            elseif opts.guestPilot == "own" then
                pcall(function() local own = gu.ps.Pilot; if U.ok(own) then e.Pilot = own end end)
            end
        end)
        if not okH then return nil, "guest entry " .. tostring(base + 1) .. ": " .. tostring(errH) end
        pnums[g] = gu.pnum
        local dressed, psCopied, miss = 0, 0, {}
        for j = 2, S do
            local okD = pcall(function()
                local src, dst = racers[j], racers[base + j]
                dst.Pilot = src.Pilot
                dst.VehicleType = src.VehicleType
                dst.VehicleCustomisation = src.VehicleCustomisation
                dressed = dressed + 1
                local sps, dps = src.Player, dst.Player
                if U.ok(sps) and U.ok(dps) then
                    local okP = pcall(function() dps.Pilot = sps.Pilot end)
                    pcall(function() dps.RacerStyle = sps.RacerStyle end)
                    local okB = pcall(function() dps.RacerBuildState = sps.RacerBuildState end)
                    if okP then psCopied = psCopied + 1 end
                    if not okB then miss[#miss + 1] = tostring(base + j) end
                end
            end)
            if not okD then miss[#miss + 1] = "entry " .. tostring(base + j) end
        end
        notes[#notes + 1] = string.format("set %d = P%d (entry %d) + %d copied opponent(s) (%d bot PlayerState(s) "
            .. "re-dressed%s)", g + 1, gu.pnum, base + 1, dressed, psCopied,
            #miss > 0 and (", build state not copied: " .. table.concat(miss, " ")) or "")
    end
    local opp = {}
    for j = 2, S do
        local okN, nm = pcall(function() return nameOf(racers[j].Pilot) end)
        opp[#opp + 1] = okN and nm or "?"
    end
    plan = { S = S, nG = nG, pnums = pnums, n = n, gen = St.worldGen, kind = opts.kind, ev = opts.ev,
             h2h = opts.h2h == true, rival = opts.rival == true, fullS = math.max(S, fullS) }
    U.log(TAG, "kickoff grid: %d instance(s) x %d racers = %d (set 1 = P1 + %s); %s%s", 1 + nG, S, n,
        table.concat(opp, ", "), table.concat(notes, "; "),
        #swaps > 0 and ("; each guest once: " .. table.concat(swaps, ", ")) or "")
    return nG
end

local recipeRacers, humanPcs                 -- (race world, below)

---------------------------------------------------------------------------------------------------- 1-car tests
-- couch-fieldtest (#34 / #35, Jules's design for every race-alone event): a single-player test whose grid holds only
-- the players (a campaign FIELD TEST: TimeTrial / PrecisionDriving / RamjetDistance, GridMakeup PlayerChoice x1 grown to
-- 1 + guests by couch.patchTimeTrials) gives each player his OWN set of one car: the other players' cars hidden in his
-- view, no collision with them, his own place / timer / result. The sets are the players themselves (the grid order of
-- the guests' entries is couch.patchGrid's, not a set layout). A test with its own opponents on the grid (SHK_BAT
-- Takedowns: Car x8 + 7 CustomOpponents) is planned in PaddockGameMode:FinishLeaving instead (#37 / #39 / #51, couch.fieldTestPre / Post:
-- the event's grid grown to N x 8, each guest's set re-dressed from P1's = M.assignGrid, plan.kind "fieldtest"); here
-- it is already planned (returns true at once), or it fell back (WARN below).
-- couch.lua's phase listener calls this at PRERACE (before its own ghosting decision). -> planned (bool)
function M.planSolo(why)
    if plan then return true end
    if not M.enabled() or opt("CouchSoloInstances", true) ~= true then return false end
    local racers = recipeRacers()
    local n = U.arrayCount(racers)
    local pcs = humanPcs()
    local pnums, nH, have = {}, 0, {}
    for pnum, pc in pairs(pcs) do
        local ps = nil
        pcall(function() ps = pc.PlayerState end)
        if U.ok(ps) then
            nH = nH + 1
            have[U.key(ps)] = true
            if pnum ~= 1 then pnums[#pnums + 1] = pnum end
        end
    end
    if nH < 2 or not pcs[1] then return false end
    local humansIn = 0
    for i = 1, n do
        local ps = nil
        pcall(function() ps = racers[i].Player end)
        if U.ok(ps) and have[U.key(ps)] then humansIn = humansIn + 1 end
    end
    if n ~= nH or humansIn ~= nH then
        -- #39: every field test runs as instances; a multi-car one is planned in FinishLeaving (#51, couch.fieldTestPre
        -- / fieldTestPost). Reaching this = that kickoff did not happen or failed (its own WARN says why)
        U.warn(TAG, "%s: NO INSTANCES - shared field (grid of %d racer(s), %d of them the %d player(s): the test's own "
            .. "opponents were not copied per player at the kickoff; the players ghosted, one field for all)",
            tostring(why), n, humansIn, nH)
        return false
    end
    table.sort(pnums)
    plan = { S = 1, nG = #pnums, pnums = pnums, n = n, gen = St.worldGen, solo = true }
    U.log(TAG, "%s: %d instance(s) x 1 car (P1, %s): each player races his own test", tostring(why), nH,
        table.concat((function() local t = {} for _, p in ipairs(pnums) do t[#t + 1] = "P" .. p end return t end)(), ", "))
    return true
end

---------------------------------------------------------------------------------------------------- race world
recipeRacers = function()
    local rs = U.giSubsystem("EventRecipeSubsystem")
    if not (U.ok(rs) and U.ok(rs.ActiveRecipe)) then return nil end
    return rs.ActiveRecipe.RecipeState.Racers
end

humanPcs = function()
    -- [pnum] = pc: P1 = the first local player, the guests by join's pnum
    local out = {}
    pcall(function()
        local lps = U.localPlayers()
        if lps[1] and U.ok(lps[1].pc) then out[1] = lps[1].pc end
    end)
    pcall(function()
        for _, e in ipairs(U.mod("join").joinedList()) do if U.ok(e.pc) then out[e.pnum] = e.pc end end
    end)
    return out
end

local function pawnsByPs()
    local out, n = {}, 0
    pcall(function()
        local vs = U.gs().Vehicles
        for i = 1, U.arrayCount(vs) do
            local v = vs[i]
            if U.ok(v) then
                local ps = v.PlayerState
                if U.ok(ps) then out[U.key(ps)] = v; n = n + 1 end
            end
        end
    end)
    return out, n
end

local function fallback(why)
    stats.fallbacks = stats.fallbacks + 1
    U.warn(TAG, "FALLBACK to the shared field (%s): every set races together, the humans ghosted", tostring(why))
    race = { ok = false, why = why, gen = St.worldGen }
    pcall(function() U.mod("couch").ghostCars("instances fallback") end)
end

-- PRERACE (+800 ms) / RACING / retries: the sets of this race world, each human's hidden list, the cross-set
-- collision ignore. Idempotent per world: actors already handled are skipped.
function M.assign(why)
    if not plan then return 0 end
    if race and race.gen == St.worldGen and race.ok == false then return 0 end   -- fell back in this world
    local racers = recipeRacers()
    local n = U.arrayCount(racers)
    if n ~= plan.n then
        fallback(string.format("race recipe has %d racer(s), the kickoff built %d", n, plan.n))
        return 0
    end
    if not (race and race.gen == St.worldGen) then
        race = { ok = true, gen = St.worldGen, sets = {}, setOf = {}, owner = {}, pawnDone = {}, hid = {}, ign = 0,
                 missing = 0, loggedColl = false, finish = {} }
    end
    local S = plan.S
    local pcs = humanPcs()
    -- sets from the recipe order
    for s = 0, plan.nG do
        local set = race.sets[s + 1] or { recs = {}, ps = {}, owner = (s == 0) and 1 or plan.pnums[s] }
        race.sets[s + 1] = set
        set.ps = {}
        for j = 1, S do
            local ps = nil
            if plan.solo then
                pcall(function() ps = pcs[set.owner].PlayerState end)    -- couch-fieldtest: the player IS his set
            else
                pcall(function() ps = racers[s * S + j].Player end)
            end
            if U.ok(ps) then
                set.ps[#set.ps + 1] = ps
                race.setOf[U.key(ps)] = s + 1
            end
        end
    end
    -- every human's PlayerState is the first entry of his own set
    for s, set in ipairs(race.sets) do
        local pc = pcs[set.owner]
        local hps = nil
        pcall(function() hps = pc.PlayerState end)
        if not (U.ok(hps) and set.ps[1] and U.key(set.ps[1]) == U.key(hps)) then
            fallback(string.format("set %d's first racer is not P%s's PlayerState", s, tostring(set.owner)))
            return 0
        end
        race.owner[s] = pc
    end
    -- pawns
    local byPs, nVeh = pawnsByPs()
    local setPawns, missing = {}, 0
    for s, set in ipairs(race.sets) do
        setPawns[s] = {}
        for _, ps in ipairs(set.ps) do
            local pawn = byPs[U.key(ps)]
            if pawn then setPawns[s][#setPawns[s] + 1] = pawn else missing = missing + 1 end
        end
    end
    race.missing = missing
    -- per-view hide: each human's PC hides every other set's cars
    local hideNotes = {}
    for s, set in ipairs(race.sets) do
        local pc = race.owner[s]
        local arr = nil
        pcall(function() arr = pc.HiddenActors end)
        if arr == nil then
            fallback("P" .. tostring(set.owner) .. "'s PlayerController has no HiddenActors")
            return 0
        end
        local hk = race.hid[s]
        if not hk then
            local before = U.arrayCount(arr)
            pcall(function() arr:Empty() end)
            hk = { n = 0, keys = {} }
            race.hid[s] = hk
            if before > 0 then U.log(TAG, "P%d's HiddenActors had %d entr(ies) before the race: emptied", set.owner, before) end
        end
        local added = 0
        for o, list in ipairs(setPawns) do
            if o ~= s then
                for _, pawn in ipairs(list) do
                    local k = U.key(pawn)
                    if not hk.keys[k] then
                        local okA = pcall(function() arr[U.arrayCount(arr) + 1] = pawn end)
                        if okA then hk.keys[k] = true; hk.n = hk.n + 1; added = added + 1 end
                    end
                end
            end
        end
        hideNotes[#hideNotes + 1] = string.format("P%d hides %d car(s)%s", set.owner, hk.n,
            added > 0 and string.format(" (+%d)", added) or "")
    end
    -- collision: every car's root ignores every car of the other sets when it moves (sweeps)
    local ign = 0
    for s, list in ipairs(setPawns) do
        for _, pawn in ipairs(list) do
            local k = U.key(pawn)
            if not race.pawnDone[k] then
                local root = nil
                pcall(function() root = pawn:K2_GetRootComponent() end)
                if U.ok(root) then
                    for o, other in ipairs(setPawns) do
                        if o ~= s then
                            for _, b in ipairs(other) do
                                if pcall(function() root:IgnoreActorWhenMoving(b, true) end) then ign = ign + 1 end
                            end
                        end
                    end
                    if not race.loggedColl then
                        race.loggedColl = true
                        local ot, prof = "?", "?"
                        pcall(function() ot = tostring(root:GetCollisionObjectType()) end)
                        pcall(function() prof = root:GetCollisionProfileName():ToString() end)
                        U.log(TAG, "collision: car roots are %s (object type %s, profile %s); cross-set pairs ignore "
                            .. "each other's SWEEPS only - a physics bump between sets = report it", nameOf(root), ot, prof)
                    end
                    -- only complete when every other set's pawn existed (a late pawn re-runs this one)
                    if missing == 0 then race.pawnDone[k] = true end
                end
            end
        end
    end
    race.ign = race.ign + ign
    race.setPawns = setPawns
    local sepNote = M.separate(setPawns)
    -- #84 / #85: the hazards already in the world (level mines, abilities spawned before the notify) once per assign
    U.try(TAG, M.hazScan, why)
    stats.assigned = stats.assigned + 1
    U.log(TAG, "%s: %d set(s) x %d, %d/%d car(s) found (GameState.Vehicles %d)%s; per-view hide: %s; collision "
        .. "ignore +%d pair(s) (%d total)%s", tostring(why), #race.sets, S, plan.n - missing, plan.n, nVeh,
        missing > 0 and " - retry for the missing ones" or "", table.concat(hideNotes, ", "), ign, race.ign,
        sepNote and ("; " .. sepNote) or "")
    if missing > 0 and (race.retries or 0) < 10 then
        race.retries = (race.retries or 0) + 1
        -- the try number is captured: a retry that lands after the world changed (race = nil) must not index it
        local nTry = race.retries
        U.mod("sched").after("instances.retry", 1000, function() U.try(TAG, M.assign, "retry " .. nTry) end)
    end
    return #race.sets
end

---------------------------------------------------------------------------------------------------- set channels (#59)
M.CH_VEHICLE = 6                      -- ECC_Vehicle
M.CH_FIRST = 21                       -- ECC_GameTraceChannel8: set 2; set 3 = 22, set 4 = 23 (unused by the game)
M.R_IGNORE = 0
local REASSERT_MS = 100

function M.channelOf(s) if s and s >= 2 then return M.CH_FIRST + s - 2 end; return M.CH_VEHICLE end

local function collMode() return tostring(opt("CouchInstancesCollision", "channels")) end

-- a car's primitives that collide as Vehicle (the root first; welded parts keep their own body filters)
local primCls = nil
local function vehiclePrims(pawn)
    local out, seen = {}, {}
    local function add(c)
        if U.ok(c) and not seen[U.key(c)] then
            local t = nil
            pcall(function() t = tonumber(c:GetCollisionObjectType()) end)
            if t == M.CH_VEHICLE then seen[U.key(c)] = true; out[#out + 1] = c end
        end
    end
    pcall(function() add(pawn:K2_GetRootComponent()) end)
    pcall(function()
        if not U.ok(primCls) then primCls = U.class("/Script/Engine.PrimitiveComponent") end
        for _, c0 in ipairs(U.arrayToTable(pawn:K2_GetComponentsByClass(primCls))) do
            -- live 2026-10-14 (couch.ghostCars): the elements are RemoteUnrealParams: :get() the component
            local c = c0
            if type(c0) == "userdata" and not U.ok(c0) then pcall(function() c = c0:get() end) end
            add(c)
        end
    end)
    return out
end

-- one primitive of set s onto its channel. -> ok
local function applyChannel(e)
    local c, s = e.comp, e.set
    local ch = M.channelOf(s)
    return pcall(function()
        -- the game's current answer to Vehicle (its profile: Vehicle Block, Vehicle_NoBattling Ignore) becomes the
        -- answer to this set's own channel
        local r6 = tonumber(c:GetCollisionResponseToChannel(M.CH_VEHICLE)) or 2
        c:SetCollisionObjectType(ch)
        c:SetCollisionResponseToChannel(ch, e.ghost and M.R_IGNORE or r6)
        c:SetCollisionResponseToChannel(M.CH_VEHICLE, M.R_IGNORE)
        for t = s + 1, race.nSets do c:SetCollisionResponseToChannel(M.channelOf(t), M.R_IGNORE) end
        -- #84: a player out of his race (finished / wrecked): his car touches no car at all
        if e.ghost then for t = 2, race.nSets do c:SetCollisionResponseToChannel(M.channelOf(t), M.R_IGNORE) end end
    end)
end

-- every object type a car of this race can have: Vehicle (set 1) + each guest set's channel
function M.vehicleChannels(nSets)
    local out = { M.CH_VEHICLE }
    for t = 2, math.max(1, tonumber(nSets) or 1) do out[#out + 1] = M.channelOf(t) end
    return out
end

-- assign: every guest set's Vehicle-type primitives get their set's channel. Idempotent (new pawns only). -> note
function M.separate(setPawns)
    if collMode() ~= "channels" or #setPawns < 2 then return nil end
    race.coll = race.coll or { list = {}, pawn = {}, fails = 0, reasserts = 0, at = -1e12, logged = false }
    race.nSets = #setPawns
    local co = race.coll
    local added, pawns = 0, 0
    for s = 2, #setPawns do
        for _, pawn in ipairs(setPawns[s]) do
            local k = U.key(pawn)
            if not co.pawn[k] then
                local prims = vehiclePrims(pawn)
                if #prims > 0 then
                    co.pawn[k] = true
                    pawns = pawns + 1
                    for _, c in ipairs(prims) do
                        local e = { comp = c, set = s }
                        if applyChannel(e) then
                            co.list[#co.list + 1] = e
                            added = added + 1
                        else
                            co.fails = co.fails + 1
                        end
                    end
                end
            end
        end
    end
    if added == 0 and co.fails == 0 then return nil end
    -- read back one primitive per set (the live check)
    local back = {}
    for s = 2, #setPawns do
        for _, e in ipairs(co.list) do
            if e.set == s then
                local t, r6, rOwn = "?", "?", "?"
                pcall(function() t = tostring(e.comp:GetCollisionObjectType()) end)
                pcall(function() r6 = tostring(e.comp:GetCollisionResponseToChannel(M.CH_VEHICLE)) end)
                pcall(function() rOwn = tostring(e.comp:GetCollisionResponseToChannel(M.channelOf(s))) end)
                back[#back + 1] = string.format("set %d type %s (Vehicle %s, own %s)", s, t, r6, rOwn)
                break
            end
        end
    end
    return string.format("set channels: %d primitive(s) of %d car(s) moved off Vehicle%s [%s]", added, pawns,
        co.fails > 0 and string.format(", %d FAILED", co.fails) or "", table.concat(back, ", "))
end

-- FAST (race): the game's own profile switch (crash / no-battling / reset) puts a car back on Vehicle: re-assert
local function collTick()
    if not (race and race.ok and race.coll and race.gen == St.worldGen) then return end
    local co = race.coll
    local now = St.nowMs()
    if now - co.at < REASSERT_MS then return end
    co.at = now
    for i = 1, #co.list do
        local e = co.list[i]
        local c = e.comp
        if not e.dead then
            -- Q8 (4 copies = 24 guest cars every 100 ms): the closure-free call (no closure / method wrapper per car)
            local t = nil
            if U.ok(c) then
                -- couch-fix40: the kept UFunction wrapper of the kept component (U.pcallFn: no method wrapper per call)
                local okT, v = U.pcallFn(c, "/Script/Engine.PrimitiveComponent:GetCollisionObjectType",
                    "GetCollisionObjectType")
                if okT then t = tonumber(v) end
            end
            if t == nil then
                e.dead = true
            elseif t ~= M.channelOf(e.set) then
                local prof = "?"
                pcall(function() prof = c:GetCollisionProfileName():ToString() end)
                applyChannel(e)
                co.reasserts = co.reasserts + 1
                if co.reasserts <= 5 or co.reasserts % 50 == 0 then
                    U.log(TAG, "set %d car back on object type %s (profile %s, the game's own switch): its set channel "
                        .. "re-asserted (%d so far)", e.set, tostring(t), prof, co.reasserts)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- #84 a: out of his race
-- Live 2026-10-18 08:50 (#84 a, gauntlet takedowns, P1 = TestBots "p1", P2 = Jules): P1 reached 8/8 at 44.50 s and
-- soloscore's finish TOOK ("P1 finished: EventFinishTime 44.56", his pause CSM left CSM_RF_InProgress, hud "P1 is out of
-- the race at 00:44.61"). What went on was his CAR: a finished car stays on the track under the AI (the game's own
-- post-finish drive; here also the TestBots SpawnAI override) with its full collision and abilities, so it kept taking
-- his copy's bots down ("P1's takedown of Autopilot NOT counted: after his own target" x14). In solo nobody sees that:
-- the race ends 2 s after the only human is out (ShouldEndRace). "race over: no human finish seen" was this module's own
-- list, filled only by the plane test's finishOf (couchrules D3), not a lost finish.
-- THIS: a set owner whose REC is no longer racing (IsStillRacing false: finished / wrecked / eliminated) LEAVES his
-- race the way solo shows it: his car is a ghost for every car (every Vehicle-type primitive answers Vehicle and every
-- set channel with Ignore, re-asserted after the game's profile switches), his sweeps ignore his own copy too, his
-- ability actors / hazards touch nobody (hazards below); his view stays in his own instance (M.viewTick: never a car
-- of another copy - the spectate of a wrecked human picks the best unfinished racer of the WHOLE grid); the finish is
-- booked in this module's list. His own finish cinematic stays native (viewguard #9 / #15 rules are not touched).
local LEAVE_MS, VIEW_MS = 250, 250

-- couch-fix40: a PlayerState's RaceEventComponent (its own component: lives as long as the PlayerState) kept per world
-- by PlayerState address, U.ok-checked at every use; IsStillRacing through the kept UFunction (U.pcallFn). Every 250 ms
-- per set owner this was a closure + 2 wrappers.
local recCache = { gen = nil, byPs = {} }
local function recOf(ps)
    if recCache.gen ~= St.worldGen then recCache.gen, recCache.byPs = St.worldGen, {} end
    local pk = U.key(ps)
    if pk == 0 then return nil end           -- couch-fix60: a dead PlayerState is never read (its memory is freed)
    local c = recCache.byPs[pk]
    if c and U.ok(c) then return c end
    local rec = nil
    pcall(function() rec = ps.RaceEventComponent end)
    rec = U.ok(rec) and rec or nil
    recCache.byPs[pk] = rec
    return rec
end

local function stillRacing(ps)
    local rec = recOf(ps)
    if not rec then return nil end
    local r = nil
    local okR, v = U.pcallFn(rec, "/Script/Griffin.PlayerRaceEventComponent:IsStillRacing", "IsStillRacing")
    if okR then r = v end
    if type(r) == "boolean" then return r end
    local out = false
    pcall(function() out = rec.bHasFinishedEvent == true or rec.bHasVehicleWrecked == true or rec.bHasBeenEliminated == true end)
    return not out
end

-- a car's primitives that collide as a car of set s (Vehicle, or the set's channel once moved)
local function carPrims(pawn, s)
    local out, seen = {}, {}
    local want = { [M.CH_VEHICLE] = true, [M.channelOf(s)] = true }
    local function add(c)
        if U.ok(c) and not seen[U.key(c)] then
            local t = nil
            pcall(function() t = tonumber(c:GetCollisionObjectType()) end)
            if t and want[t] then seen[U.key(c)] = true; out[#out + 1] = c end
        end
    end
    pcall(function() add(pawn:K2_GetRootComponent()) end)
    pcall(function()
        if not U.ok(primCls) then primCls = U.class("/Script/Engine.PrimitiveComponent") end
        for _, c0 in ipairs(U.arrayToTable(pawn:K2_GetComponentsByClass(primCls))) do
            local c = c0
            if type(c0) == "userdata" and not U.ok(c0) then pcall(function() c = c0:get() end) end
            add(c)
        end
    end)
    return out
end

local function ghostPrim(c, nSets)
    return pcall(function()
        for _, ch in ipairs(M.vehicleChannels(nSets)) do c:SetCollisionResponseToChannel(ch, M.R_IGNORE) end
    end)
end

-- the set s owner's car (nil = none yet)
local function ownerCar(s)
    local list = race.setPawns and race.setPawns[s] or nil
    local set = race.sets[s]
    if not (list and set and set.ps[1]) then return nil end
    local hk = U.key(set.ps[1])
    if hk == 0 then return nil end
    for _, p in ipairs(list) do
        -- couch-fix60 (AUTO-146): a kept pawn is checked before its member read (a collected one = an AV pcall misses)
        if U.ok(p) then
            local ps = nil
            pcall(function() ps = p.PlayerState end)
            if U.ok(ps) and U.key(ps) == hk then return p end
        end
    end
    return nil
end

function M.leave(s, how)
    if not (race and race.ok) then return false end
    race.left = race.left or {}
    if race.left[s] then return false end
    local set = race.sets[s]
    if not set then return false end
    race.left[s] = { how = how, at = St.nowMs() }
    local car = ownerCar(s)
    local n, sw = 0, 0
    if car then
        -- every primitive of his car colliding as a car: Ignore every car type (set 1's are watched in race.ghosts,
        -- a guest set's through its channel entries: applyChannel keeps the ghost)
        race.ghosts = race.ghosts or {}
        local k = U.key(car)
        local co = race.coll
        local inList = {}
        if co then
            for _, e in ipairs(co.list) do
                if e.set == s and not e.dead and U.ok(e.comp) then   -- couch-fix60: a kept component checked first
                    local okO = false
                    pcall(function() okO = U.key(e.comp:GetOwner()) == k end)
                    if okO then e.ghost = true; applyChannel(e); inList[U.key(e.comp)] = true; n = n + 1 end
                end
            end
        end
        for _, c in ipairs(carPrims(car, s)) do
            if not inList[U.key(c)] and ghostPrim(c, race.nSets or #race.sets) then
                race.ghosts[#race.ghosts + 1] = { comp = c, set = s }
                n = n + 1
            end
        end
        -- his sweeps ignore his own copy too
        local root = nil
        pcall(function() root = car:K2_GetRootComponent() end)
        if U.ok(root) then
            for _, b in ipairs(race.setPawns[s] or {}) do
                if U.key(b) ~= k and pcall(function() root:IgnoreActorWhenMoving(b, true) end) then sw = sw + 1 end
            end
        end
    end
    -- the finish list (the race-over line; couchrules' D3 finishOf books the plane test's own entry)
    local seen = false
    for _, f in ipairs(race.finish) do if f.pnum == set.owner then seen = true end end
    if not seen then
        -- couch-fix61 (AUTO-150d, live round 6 09:45:12: "race over: P1 place 2" for a P1 booked and shown 1st): the
        -- place is read fresh at the finish, never from the 200 ms rank cache of the lap before the line
        M._posFresh()
        local lp = M.localPosition(set.ps[1])
        race.finish[#race.finish + 1] = { pnum = set.owner, pos = how == "finished" and lp or nil, how = how }
    end
    -- his hazards / ability actors: no car at all from now on
    local hz = race.hz
    local nh = 0
    if hz then
        for _, h in pairs(hz.list) do
            if h.set == s and not h.ghost then h.ghost = true; M._hazApply(h); nh = nh + 1 end
        end
    end
    U.log(TAG, "P%s is out of his race (%s): he leaves it as in solo - his car a ghost for every car (%d primitive(s), "
        .. "%d own-copy sweep(s)), %d hazard(s) of his off, his view kept in his own instance (V-INST-LEAVE)",
        tostring(set.owner), tostring(how), n, sw, nh)
    return true
end

local function leaveTick(now)
    if now - (race.leaveAt or -1e12) < LEAVE_MS then return end
    race.leaveAt = now
    for s, set in ipairs(race.sets) do
        if not (race.left and race.left[s]) and U.ok(set.ps[1]) then
            local r = stillRacing(set.ps[1])
            if r == false then
                local rec = recOf(set.ps[1])
                local how = "finished"
                pcall(function()
                    if rec.bHasVehicleWrecked == true then how = "wrecked"
                    elseif rec.bHasBeenEliminated == true then how = "eliminated" end
                end)
                M.leave(s, how)
            end
        end
    end
    -- the ghost primitives after the game's own profile switch (it answers its own car type again)
    for _, g in ipairs(race.ghosts or {}) do
        if not g.dead then
            local r = nil
            if U.ok(g.comp) then
                pcall(function()
                    r = tonumber(g.comp:GetCollisionResponseToChannel(tonumber(g.comp:GetCollisionObjectType())))
                end)
            end
            if r == nil then g.dead = true
            elseif r ~= M.R_IGNORE then
                ghostPrim(g.comp, race.nSets or #race.sets)
                race.ghostReasserts = (race.ghostReasserts or 0) + 1
            end
        end
    end
end

-- a view on a car of ANOTHER copy -> back into his own instance: his copy's best racer still racing, else his own car
-- (the native spectate of a wrecked human, StartSpectatingBestRacer, ranks the whole grid)
local function ownView(s)
    local best, bestPos = nil, 1e9
    local byKey = {}
    for _, p in ipairs(race.setPawns and race.setPawns[s] or {}) do
        if U.ok(p) then                                       -- couch-fix60
            local ps = nil
            pcall(function() ps = p.PlayerState end)
            if U.ok(ps) then byKey[U.key(ps)] = p end
        end
    end
    for j, ps in ipairs(race.sets[s].ps) do
        local p = byKey[U.key(ps)]
        if p and j > 1 and stillRacing(ps) == true then
            local pos = 1e8
            if U.ok(ps) then pcall(function() pos = tonumber(ps.RaceEventComponent.EventPosition) or pos end) end
            if pos < bestPos then best, bestPos = p, pos end
        end
    end
    if race.left and race.left[s] and race.left[s].how ~= "finished" and best then return best end
    return ownerCar(s) or best
end

function M.viewTick(now)
    if not (race and race.ok and race.gen == St.worldGen) then return end
    if now - (race.viewAt or -1e12) < VIEW_MS then return end
    race.viewAt = now
    for s, pc in pairs(race.owner or {}) do
        if U.ok(pc) then
            local okV, vt = U.pcallFn(pc, "/Script/Engine.PlayerController:GetViewTarget", "GetViewTarget")  -- couch-fix40
            if not okV then vt = nil end
            if U.ok(vt) and U.isVehicle(vt) then
                local vps = nil
                pcall(function() vps = vt.PlayerState end)
                local vs = U.ok(vps) and race.setOf[U.key(vps)] or nil
                if vs and vs ~= s then
                    local to = ownView(s)
                    local ok = false
                    if U.ok(to) then ok = pcall(function() pc:SetViewTargetWithBlend(to, 0.0, 0, 0.0, false) end) end
                    race.viewFix = (race.viewFix or 0) + 1
                    if race.viewFix <= 5 or race.viewFix % 25 == 0 then
                        U.log(TAG, "P%s's view was on a car of copy %d (%s): back into his own copy (%s) %s (%d so far) "
                            .. "(V-INST-VIEW)", tostring(race.sets[s].owner), vs, psName(vps),
                            U.ok(to) and nameOf(to) or "no car", ok and "ok" or "FAILED", race.viewFix)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------- #84 b / #85: hazards per set
-- #84 b (Jules, P2): "bots destroyed in front of me by P1 that I could not destroy myself"; #85 (ramjet distance test,
-- Crait, 08:55): "P1's mines explode on P2's screen, P2 gets no effect, P2's instance has no hazards of its own".
-- The per-set car channels (#59) cover car-to-car contact only. Everything else a car meets is an ACTOR of its own
-- (JMAP CL381121, jmapq): ProximityMine (<- GfnCustomObstacle <- GfnObstacleBase <- Actor; OwnerVehicle +0x320,
-- TriggerArea +0x3d0 / EffectArea +0x2d8 SphereComponent: the mine's trigger and blast are overlaps), the abilities'
-- AbilityOverlapHelper (mOwningVehicle +0x2e8, mOverlapComponents: shockwaves / discharges / punches hit by overlap),
-- AbilityFeedback (ParentAbility +0x2d0 -> GfnAbility.OwningPlayer +0x4c0: the explosions / shock rings on screen) and
-- GfnAbility itself. Two faults followed: (1) an actor of one copy overlaps the other copy's cars (set 1's mine sphere
-- answers the unused channel 21 with the default Block, the car of set 2 answers its object type with Overlap) and its
-- visuals are in every view (HiddenActors held only the cars); (2) a set-2 car (object type 21) is invisible to every
-- hazard that only answers Vehicle (6): the level's mines never touched P2 (#85: "no effect"), nor did set 2's own.
-- AbilityMineConfig.MineDefinition is the only class reference to ProximityMine in the JMAP: the test's track mines
-- (BP_Mine_Concussion / BP_BaseConcussionMine_C) are placed actors without an OwnerVehicle = ONE copy for the race.
-- THIS (cfg.CouchInstanceHazards, instances only): every hazard actor is owned by a set (its owner car's set; an
-- ownerless one is a WORLD hazard: set 1's, and every guest set gets its own copy - same class, same transform, the
-- mine's reflected tuning copied before FinishSpawningActor, as chasecam spawns its rig); its primitives answer their
-- own set's car type as they answered Vehicle and Ignore every other set's (a ghost owner's: every car type); it is in
-- the HiddenActors of every other set's player. New actors report through NotifyOnNewObject (store only); level actors
-- are found once per assign (FindAllOf). Reasserted every 250 ms (a profile switch of the actor puts them back).
-- Damage that is not an overlap: AbilityShockwaveSource:Multi_AddVehicle(VehiclePawn, Strength) pre-hook - a push of
-- another set's car gets Strength 0; VehicleGameplayComponent:Server_OnVehicleDamaged(victim, Instigator, Damage, ..) and
-- VehicleBlameComponent:Server_AddBlameContributor(Aggressor, ..) across sets are counted / logged (Damage -> 0).
-- [?] live: UE4SS param :set() in a native pre-hook reaches the body; the mine copies arm / explode / apply their
-- condition to P2's car (the mine's own overlap code; an object-type query on Vehicle would still miss type 21);
-- NotifyOnNewObject fires for the mines of an AI's ability; the explosion FX are the actor's own components (hidden
-- with it) and not spawned at a location.
M.HAZ_PATHS = { "/Script/Griffin.ProximityMine", "/Script/Griffin.AbilityOverlapHelper",
                "/Script/Griffin.AbilityFeedback", "/Script/Griffin.GfnAbility" }
M.HAZ_SCAN = { "ProximityMine", "AbilityOverlapHelper" }
M.MINE_COPY_PROPS = { "MinSpeedForPhysics", "GravityScale", "DragTime", "DragK", "DragPower", "ArmingTime",
    "EffectDuration", "LingeringDuration", "TriggerExplosionScale", "MinExplosionScale", "TriggeredByOwner",
    "AffectsOwner", "AwardsEnergy", "ShieldBreakAppliesLinger", "ConditionTagsToApply", "LingeringConditionTagsToApply",
    "ObstacleDanger", "ChanceMinePerceivable", "ObstacleRadiusScalarWhenNotPerceivable", "ObstacleRadiusScalar",
    "IsInitialSpeedPercentage", "InitialSpeed", "ApplyInitialSpeedAngle", "InitialSpeedAngle", "InitialScale",
    "TimeToScale", "MinTimePhysical", "ApplyRandomInitialAngularVelocity", "MaxInitialAngularVelocity",
    "ExplodeOnWorldContact", "GroundMaterial", "GroundLocation", "GroundNormal", "FreezingMine" }
local HAZ_SETTLE_MS, HAZ_MS, HAZ_SEEN_MAX, HAZ_WAIT_MS = 1000, 250, 512, 3000
local SPAWN_ALWAYS, SCALE_MULTIPLY = 1, 1
local hazSeen = {}
local hstats = { seen = 0, owned = 0, world = 0, copies = 0, copyFails = 0, pushes = 0, damage = 0, blame = 0 }
function M.hazStats() return hstats end

-- NotifyOnNewObject (M.init): store only, the object is still being constructed. couch-fix52 (AUTO-136,
-- crash_2026_10_18_16_39_28): the entry carries its world; hazTick drops the other worlds' (see hazTake)
function M._hazSeen(obj)
    if obj == nil then return end
    hazSeen[#hazSeen + 1] = { o = obj, at = St.nowMs(), gen = St.worldGen }
    if #hazSeen > HAZ_SEEN_MAX then table.remove(hazSeen, 1) end
end

local function hazOn() return opt("CouchInstanceHazards", true) == true end

-- the responses of a hazard primitive of set `set` (nil = none to write). r6 = its own answer to Vehicle before the
-- mod touched it. -> { {ch, resp}... }
function M.hazResponses(set, nSets, r6, ghost)
    local out = {}
    r6 = tonumber(r6) or 2
    for t = 1, math.max(1, nSets) do
        local ch = M.channelOf(t)
        local r = M.R_IGNORE
        if t == set and not ghost then r = r6 end
        out[#out + 1] = { ch, r }
    end
    return out
end

local function vehPs(v)
    if not (U.ok(v) and U.isVehicle(v)) then return nil end
    local ps = nil
    pcall(function() ps = v.PlayerState end)
    return U.ok(ps) and ps or nil
end

-- -> owner PlayerState (nil = none / not known yet), kind
local function hazOwner(a)
    if U.isA(a, "/Script/Griffin.ProximityMine") then
        local v = nil
        pcall(function() v = a.OwnerVehicle end)
        return vehPs(v), "mine"
    end
    if U.isA(a, "/Script/Griffin.AbilityOverlapHelper") then
        local v = nil
        pcall(function() v = a.mOwningVehicle end)
        return vehPs(v), "overlap"
    end
    if U.isA(a, "/Script/Griffin.AbilityFeedback") then
        local ps = nil
        pcall(function() ps = a.ParentAbility.OwningPlayer end)
        return U.ok(ps) and ps or nil, "feedback"
    end
    if U.isA(a, "/Script/Griffin.GfnAbility") then
        local ps = nil
        pcall(function() ps = a.OwningPlayer end)
        return U.ok(ps) and ps or nil, "ability"
    end
    return nil, nil                    -- couch-fix52: not a hazard class (a stale entry's address reused): never taken
end

local function hazPrims(a)
    local out = {}
    pcall(function()
        if not U.ok(primCls) then primCls = U.class("/Script/Engine.PrimitiveComponent") end
        for _, c0 in ipairs(U.arrayToTable(a:K2_GetComponentsByClass(primCls))) do
            local c = c0
            if type(c0) == "userdata" and not U.ok(c0) then pcall(function() c = c0:get() end) end
            if U.ok(c) then out[#out + 1] = c end
        end
    end)
    return out
end

function M._hazApply(h)
    local n = race and race.nSets or 1
    for _, p in ipairs(h.prims) do
        if U.ok(p.c) then
            if p.r6 == nil then pcall(function() p.r6 = tonumber(p.c:GetCollisionResponseToChannel(M.CH_VEHICLE)) end) end
            pcall(function()
                for _, cr in ipairs(M.hazResponses(h.set, n, p.r6, h.ghost)) do
                    p.c:SetCollisionResponseToChannel(cr[1], cr[2])
                end
            end)
        else
            p.dead = true
        end
    end
end

-- one foreign channel per primitive answers Ignore? (the reassert check)
local function hazIntact(h)
    local n = race.nSets or 1
    for _, p in ipairs(h.prims) do
        if not p.dead and U.ok(p.c) then
            for _, cr in ipairs(M.hazResponses(h.set, n, p.r6, h.ghost)) do
                if cr[2] == M.R_IGNORE then
                    local r = nil
                    pcall(function() r = tonumber(p.c:GetCollisionResponseToChannel(cr[1])) end)
                    if r ~= nil and r ~= M.R_IGNORE then return false end
                    break
                end
            end
        end
    end
    return true
end

local function hazHide(h)
    for s, pc in pairs(race.owner or {}) do
        if s ~= h.set and U.ok(pc) then
            local hk = race.hid[s]
            local arr = nil
            pcall(function() arr = pc.HiddenActors end)
            if hk and arr ~= nil and not hk.keys[h.key] then
                if pcall(function() arr[U.arrayCount(arr) + 1] = h.actor end) then
                    hk.keys[h.key] = true
                    hk.haz = (hk.haz or 0) + 1
                end
            end
        end
    end
end

local function hazState()
    race.hz = race.hz or { list = {}, copyOf = {}, worldDone = {}, at = -1e12, reasserts = 0, logged = {} }
    return race.hz
end

local function hazAdd(a, set, kind, why)
    local hz = hazState()
    local k = U.key(a)
    if hz.list[k] then return hz.list[k] end
    -- couch-fix52 (AUTO-136): only an AActor goes into a PlayerController's HiddenActors (see hazTake)
    if not U.isA(a, "/Script/Engine.Actor") then
        U.logEvery("instances.hazNotActor", 5000, TAG, "WARN hazard %s of copy %d (%s) is not an actor: left alone",
            nameOf(a), set, tostring(why))
        return nil
    end
    local h = { actor = a, key = k, set = set, kind = kind, prims = {} }
    for _, c in ipairs(hazPrims(a)) do h.prims[#h.prims + 1] = { c = c } end
    h.ghost = race.left and race.left[set] ~= nil or false
    hz.list[k] = h
    M._hazApply(h)
    hazHide(h)
    hstats.owned = hstats.owned + 1
    local lk = kind .. ":" .. set
    hz.logged[lk] = (hz.logged[lk] or 0) + 1
    if hz.logged[lk] <= 2 then
        U.log(TAG, "hazard %s %s of copy %d (P%s, %s): %d primitive(s) answer only copy %d's cars, hidden in the other "
            .. "copies' views%s (V-INST-HAZ)", kind, nameOf(a), set, tostring(race.sets[set] and race.sets[set].owner),
            tostring(why), #h.prims, set, h.ghost and "; its owner is out: no car at all" or "")
    end
    return h
end

-- a world hazard (no owner): set 1 keeps it, every guest set gets a copy. -> copies made
local function copyMine(mine, s)
    local gsl, world = U.GS(), U.world()
    local cls = nil
    if not U.ok(mine) then return nil, "mine gone" end
    pcall(function() cls = mine:GetClass() end)
    if not (U.ok(gsl) and U.ok(world) and U.ok(cls)) then return nil, "GameplayStatics / world / class missing" end
    local T = nil
    pcall(function() T = mine:GetTransform() end)
    if T == nil then return nil, "transform unreadable" end
    local a, copied = nil, 0
    local ok, err = pcall(function()
        a = gsl:BeginDeferredActorSpawnFromClass(world, cls, T, SPAWN_ALWAYS, nil, SCALE_MULTIPLY)
        if not U.ok(a) then error("spawn returned no actor") end
        for _, f in ipairs(M.MINE_COPY_PROPS) do
            if pcall(function() local v = mine[f]; if v ~= nil then a[f] = v end end) then copied = copied + 1 end
        end
        gsl:FinishSpawningActor(a, T, SCALE_MULTIPLY)
    end)
    if not ok then return nil, tostring(err) end
    return a, copied
end

local function worldHazard(hz, a, why)
    local k = U.key(a)
    if hz.worldDone[k] or hz.copyOf[k] then return end
    hz.worldDone[k] = true
    hstats.world = hstats.world + 1
    hazAdd(a, 1, "world mine", why)
    local made, fails, props = 0, 0, nil
    for s = 2, #race.sets do
        local c, info = copyMine(a, s)
        if c then
            hz.copyOf[U.key(c)] = s
            hazAdd(c, s, "world mine copy", "copy for copy " .. s)
            made = made + 1
            props = info
            hstats.copies = hstats.copies + 1
        else
            fails = fails + 1
            hstats.copyFails = hstats.copyFails + 1
            U.logEvery("instances.copyfail", 5000, TAG, "WARN world hazard %s: its copy for copy %d FAILED (%s): that "
                .. "player meets set 1's mine only through the shared channel", nameOf(a), s, tostring(info))
        end
    end
    hz.worldN = (hz.worldN or 0) + 1
    if hz.worldN <= 3 or hz.worldN % 25 == 0 then
        U.log(TAG, "world hazard %s (no owner car, %s): copy 1 keeps it, %d copy(ies) spawned for the guests' copies "
            .. "(%s reflected tuning value(s) each)%s (%d world hazard(s) so far) (V-INST-HAZ85)", nameOf(a), tostring(why),
            made, tostring(props), fails > 0 and (", " .. fails .. " FAILED") or "", hz.worldN)
    end
end

-- one actor: owned (its copy) / world (copies) / not known yet (asked again until HAZ_WAIT_MS)
-- couch-fix52 (AUTO-136, crash_2026_10_18_16_39_28, takedowns field test PRERACE, 3 ms after "hazard actor
-- CustomisationRoot of copy 2 (P2, new): 0 primitive(s)"): hazSeen kept the NotifyOnNewObject entries of the previous
-- worlds (the last race, the paddock: hazTick only runs in a race) and of objects destroyed since; their address was
-- reused by a car's CustomisationRoot (a PrimitiveComponent), which IsValid passes. The generic owner branch (GetOwner =
-- the car = P2's set) took it as a "hazard actor" and hazHide put the COMPONENT into P1's PlayerController.HiddenActors
-- (TArray<AActor*>). The next frame's hidden-component build walked it as an actor: SWGR-Win64-Shipping.exe+0x2901de
-- iterates AActor::OwnedComponents (a TSet, 16-byte elements: `mov rdx,[rdi+0x238]; shl rcx,4; mov r14,[rdx+rcx]`) on
-- the component = its transform's 1.0 (rdx 0x3ff0000000000000) -> AV reading 0xffffffffffffffff. Now: an entry of
-- an older world is dropped, an object of none of the hazard classes is never taken, only an Actor is hidden.
local function hazTake(a, seenAt, now, why)
    local hz = hazState()
    local k = U.key(a)
    if hz.list[k] then return true end
    local cs = hz.copyOf[k]
    if cs then hazAdd(a, cs, "world mine copy", "copy"); return true end
    local ps, kind = hazOwner(a)
    if not kind then return true end
    if ps then
        local s = race.setOf[U.key(ps)]
        if s then hazAdd(a, s, kind, why); return true end
        return now - seenAt >= HAZ_WAIT_MS        -- an owner outside the sets: left alone
    end
    if kind == "mine" and now - seenAt >= HAZ_SETTLE_MS then worldHazard(hz, a, why); return true end
    return now - seenAt >= HAZ_WAIT_MS
end

function M.hazScan(why)
    if not (race and race.ok and hazOn() and #race.sets >= 2) then return end
    local now = St.nowMs()
    for _, cn in ipairs(M.HAZ_SCAN) do
        local okF, list = pcall(FindAllOf, cn)
        for _, a in ipairs(okF and list or {}) do
            if U.ok(a) then
                -- a level mine was there before the race: no settle wait
                pcall(hazTake, a, now - HAZ_SETTLE_MS, now, "found at " .. tostring(why))
            end
        end
    end
end

function M.hazTick(now)
    if not (race and race.ok and race.gen == St.worldGen and hazOn() and #race.sets >= 2) then return end
    local hz = hazState()
    if now - hz.at < HAZ_MS then return end
    hz.at = now
    local keep = {}
    for _, e in ipairs(hazSeen) do
        hstats.seen = hstats.seen + 1
        local done = true
        -- couch-fix52: an object of an older world (the race's own load may still count as the transition world's)
        if (tonumber(e.gen) or -1) < (tonumber(race.gen) or 0) - 1 then
            hstats.stale = (hstats.stale or 0) + 1
        elseif U.ok(e.o) then
            local ok, d = pcall(hazTake, e.o, e.at, now, "new")
            done = (not ok) or d
        end
        if not done then keep[#keep + 1] = e end
    end
    hazSeen = keep
    for k, h in pairs(hz.list) do
        if not U.ok(h.actor) then
            hz.list[k] = nil
        elseif not hazIntact(h) then
            M._hazApply(h)
            hz.reasserts = hz.reasserts + 1
        end
    end
end

-- the set of a damage / push party: a PlayerState, a VehiclePawn, or a component / actor owned by one
local function setOfAny(o)
    o = U.unwrap(o)
    if not U.ok(o) then return nil end
    local s = race.setOf[U.key(o)]
    if s then return s end
    local ps = vehPs(o)
    if ps then return race.setOf[U.key(ps)] end
    local hz = race.hz
    if hz and hz.list[U.key(o)] then return hz.list[U.key(o)].set end
    local own = nil
    pcall(function() own = o:GetOwner() end)
    if U.ok(own) then
        if hz and hz.list[U.key(own)] then return hz.list[U.key(own)].set end
        ps = vehPs(own)
        if ps then return race.setOf[U.key(ps)] end
        local p2 = nil
        pcall(function() p2 = hazOwner(own) end)
        if U.ok(p2) then return race.setOf[U.key(p2)] end
    end
    return nil
end

local function setParam(p, v)
    if type(p) == "table" and type(p.set) == "function" then return pcall(p.set, p, v) end
    return pcall(function() p:set(v) end)
end

-- pre-hook AbilityShockwaveSource:Multi_AddVehicle(VehiclePawn, Strength): a push of another copy's car -> Strength 0
function M.onShockwaveAdd(ctx, veh, strength)
    if not (race and race.ok and race.gen == St.worldGen and hazOn()) then return end
    local a, b = setOfAny(ctx), setOfAny(veh)
    if a and b and a ~= b then
        local ok = setParam(strength, 0.0)
        hstats.pushes = hstats.pushes + 1
        U.logEvery("instances.push", 3000, TAG, "a shockwave of copy %d pushed a car of copy %d: Strength -> 0 %s (%d so far) "
            .. "(V-INST-PUSH)", a, b, ok and "ok" or "FAILED", hstats.pushes)
    end
end

-- pre-hook VehicleGameplayComponent:Server_OnVehicleDamaged(victim, Instigator, Damage, Severity)
function M.onDamaged(_, victim, inst, dmg)
    if not (race and race.ok and race.gen == St.worldGen and hazOn()) then return end
    local a, b = setOfAny(inst), setOfAny(victim)
    if a and b and a ~= b then
        local ok = setParam(dmg, 0.0)
        hstats.damage = hstats.damage + 1
        U.logEvery("instances.dmg", 3000, TAG, "damage across copies: %s (copy %d) on %s (copy %d): Damage -> 0 %s (%d so far) "
            .. "(V-INST-DMG)", psName(U.unwrap(inst)), a, psName(U.unwrap(victim)), b, ok and "ok" or "FAILED", hstats.damage)
    end
end

-- pre-hook VehicleBlameComponent:Server_AddBlameContributor(Aggressor, timeForBlame, Reason) (component of the victim)
function M.onBlame(ctx, aggr)
    if not (race and race.ok and race.gen == St.worldGen and hazOn()) then return end
    local a, b = setOfAny(aggr), setOfAny(ctx)
    if a and b and a ~= b then
        hstats.blame = hstats.blame + 1
        U.logEvery("instances.blame", 3000, TAG, "blame across copies: a car of copy %d blamed for a crash of a car of copy "
            .. "%d (%d so far) (V-INST-BLAME)", a, b, hstats.blame)
    end
end

---------------------------------------------------------------------------------------------------- boss pacing (D8)
-- couch-fix38 (couchrules D8, Jules's Q12 B): in a BOSS race raced as copies, each copy of the boss paces / aims at its
-- own player. The game's director (AIRaceDirector.VehicleInfos[].RacePacingTarget) and each AI's RaceAIComponent
-- (mPawnToPaceAgainst / mAggressionTarget) are filled natively over the whole grid: a boss copy pointed at ANOTHER
-- copy's player is pointed at its own (the same writes as soloscore's takedown director, #70). Every PACE_MS.
-- couch-fix49 (AUTO-130 c, live round 2 run 42): the old tick wrote whenever a target pointed at another copy's player
-- and the game put 2 of them back every time: "2 pacing / aggression target(s) ... -> their own" ~4x/s, 1200 writes by
-- 14:08:34 - a steady fight all race. Jules: point once, re-point only on change. Each target (the director's
-- VehicleInfos entry of a boss copy, its RaceAIComponent's pace / aggression target) is pointed at its own player ONCE;
-- it is pointed again only when what it should point at changes (his car is a new pawn: a respawn) or the game moves it
-- to ANOTHER wrong player than the one it held before. The game putting it straight back where it was is left (logged
-- once per target: "the game keeps its own target").
local PACE_MS = 500
local pstats = { writes = 0, seen = 0, kept = 0 }
function M.paceStats() return pstats end

local function bossPaceTick(now)
    if now - (race.paceAt or -1e12) < PACE_MS then return end
    race.paceAt = now
    race.paceSlots = race.paceSlots or { dir = {}, pace = {}, aggr = {} }
    local slots = race.paceSlots
    local humanSet, botSet, human = {}, {}, {}
    for s in ipairs(race.sets) do
        local car = ownerCar(s)
        if car then humanSet[U.key(car)] = s; human[s] = car end
        for _, p in ipairs(race.setPawns and race.setPawns[s] or {}) do
            if not car or U.key(p) ~= U.key(car) then botSet[U.key(p)] = s end
        end
    end
    local fixed, seen, kept = 0, 0, {}
    local function fix(kind, id, s, cur, write)
        if not U.ok(cur) then return end
        local ck = U.key(cur)
        local hs = humanSet[ck]
        if hs == nil then return end
        seen = seen + 1
        if hs == s or not human[s] then return end
        local want = U.key(human[s])
        local sl = slots[kind][id]
        if sl and sl.want == want and sl.from == ck then
            -- pointed once already, the game put it back where it was: left (no fight)
            if not sl.kept then sl.kept = true; kept[#kept + 1] = kind end
            return
        end
        if pcall(write) then
            fixed = fixed + 1
            slots[kind][id] = { want = want, from = ck }
        end
    end
    pcall(function()
        local infos = U.gs().RaceDirector.VehicleInfos
        for i = 1, U.arrayCount(infos) do
            local e = infos[i]
            local v = nil
            pcall(function() v = e.Vehicle end)
            local s = U.ok(v) and botSet[U.key(v)] or nil
            if s then
                local cur = nil
                pcall(function() cur = e.RacePacingTarget end)
                fix("dir", U.key(v), s, cur, function() e.RacePacingTarget = human[s] end)
            end
        end
    end)
    for s in ipairs(race.sets) do
        for _, b in ipairs(race.setPawns and race.setPawns[s] or {}) do
            local bk = U.key(b)
            if botSet[bk] and U.ok(b) then                -- couch-fix60: a kept pawn checked first
                local ai = nil
                pcall(function() ai = b.RaceAIComponent end)
                if U.ok(ai) then
                    local p, a = nil, nil
                    pcall(function() p = ai.mPawnToPaceAgainst end)
                    pcall(function() a = ai.mAggressionTarget end)
                    fix("pace", bk, s, p, function() ai.mPawnToPaceAgainst = human[s] end)
                    fix("aggr", bk, s, a, function() ai.mAggressionTarget = human[s] end)
                end
            end
        end
    end
    pstats.seen = pstats.seen + seen
    if #kept > 0 then
        pstats.kept = pstats.kept + #kept
        U.log(TAG, "boss copies: the game keeps its own target on %d of them after one re-point (%s): left, pointed "
            .. "again only on a change (V-BOSS-PACE)", #kept, table.concat(kept, ", "))
    end
    if fixed > 0 then
        pstats.writes = pstats.writes + fixed
        U.log(TAG, "boss copies: %d pacing / aggression target(s) pointed at another copy's player -> their own (%d "
            .. "so far) (V-BOSS-PACE)", fixed, pstats.writes)
    end
end

---------------------------------------------------------------------------------------------------- boss outro (D8)
-- couch-fix49 (AUTO-130 b, live round 2 run 42 14:08:48, shot r2-a18-08-results): the full-screen outro said
-- "FINISHED - You came 3rd" while P1 was "place 2 of 2 (global 4)". Every post-race screen is created for the LAST
-- local PC (couchsolo #35): WBP_PostRace_Info's second line (Outro_FinishedPlace "You came {Place}") is the OWNER's
-- (P2's) global EventPosition - 3rd. In a boss race raced as copies the line shows P1's place in HIS OWN race (his
-- recorded result when couchrules rewrote his REC to the team's win). P1 wrecked / not finished: the game's line stays.
function M.ordinal(n)
    n = math.floor(tonumber(n) or 0)
    local m10, m100 = n % 10, n % 100
    local suf = "th"
    if m100 < 11 or m100 > 13 then
        if m10 == 1 then suf = "st" elseif m10 == 2 then suf = "nd" elseif m10 == 3 then suf = "rd" end
    end
    return tostring(n) .. suf
end

local OUTRO_CLS = "WBP_PostRace_Info_C"
local function bossOutroTick(now)
    if now - (race.outroAt or -1e12) < 1000 then return end
    race.outroAt = now
    local ps = nil
    pcall(function() ps = U.p1().PlayerState end)
    if not U.ok(ps) then return end
    local fin, wr = false, false
    pcall(function()
        local rec = ps.RaceEventComponent
        fin, wr = rec.bHasFinishedEvent == true, rec.bHasVehicleWrecked == true
    end)
    if not fin or wr then return end
    local pos = nil
    pcall(function()
        local rp, rwr = U.mod("couchrules").realResult(ps)
        if rwr ~= true and tonumber(rp) then pos = tonumber(rp) end
    end)
    if not pos then pos = M.localPosition(ps) end
    if not (pos and pos >= 1) then return end
    local want = "You came " .. M.ordinal(pos)
    local ok, list = pcall(FindAllOf, OUTRO_CLS)
    if not (ok and type(list) == "table") then return end
    for _, w in ipairs(list) do
        if U.alive(w) then
            local vis = false
            pcall(function() vis = w:IsVisible() == true end)
            if vis then
                local okS = pcall(function() w.Txt_Secondary:SetText(U.ftext(want)) end)
                race.outroDone = race.outroDone or {}
                local k = U.key(w)
                if not race.outroDone[k] then
                    race.outroDone[k] = true
                    U.log(TAG, "boss outro: \"%s\" = P1's place in his own race (the screen's owner is the last local "
                        .. "player: his global place showed) %s", want, okS and "ok" or "FAILED")
                end
            end
        end
    end
end
M._bossOutroTick = function(now) if race then return bossOutroTick(now or St.nowMs()) end end

-- FAST (race): channels, leaving players, views, hazards
-- couch-fix60 (AUTO-146): instance work only while the race world runs its race (PRERACE / RACING; POSTRACE = the
-- boss outro): never in LOADING / LEAVING / TRANSIT (main.lua's phase.fastWorldCheck leaves the race first)
local WORK_PHASE = { PRERACE = true, RACING = true, POSTRACE = true }
function M.fastTick()
    if not WORK_PHASE[St.phase] then return end
    collTick()
    if not (race and race.ok and race.gen == St.worldGen) then return end
    local now = St.nowMs()
    U.try(TAG, leaveTick, now)
    U.try(TAG, M.viewTick, now)
    U.try(TAG, M.hazTick, now)
    if plan and plan.kind == "boss" then
        if St.phase == "POSTRACE" then U.try(TAG, bossOutroTick, now) else U.try(TAG, bossPaceTick, now) end
    end
end

---------------------------------------------------------------------------------------------------- positions
-- each racer's place inside his own set: the global EventPosition order restricted to the set (cached 200 ms)
local posCache = { at = -1e12, gen = nil, by = {} }
function M._posFresh() posCache.at = -1e12 end
local function rankAll()
    local now = St.nowMs()
    if posCache.gen == St.worldGen and now - posCache.at < 200 then return posCache.by end
    local by = {}
    for _, set in ipairs(race.sets) do
        local list = {}
        for _, ps in ipairs(set.ps) do
            if U.ok(ps) then
                local pos = nil
                pcall(function() pos = tonumber(ps.RaceEventComponent.EventPosition) end)
                if type(pos) == "number" and pos > 0 then list[#list + 1] = { k = U.key(ps), pos = pos } end
            end
        end
        table.sort(list, function(a, b) return a.pos < b.pos end)
        for i, r in ipairs(list) do by[r.k] = { pos = i, global = r.pos, of = #set.ps } end
    end
    posCache.at, posCache.gen, posCache.by = now, St.worldGen, by
    return by
end

-- -> own-set place, global place, set size (nil when no instances run)
function M.localPosition(ps)
    if not M.active() or not U.ok(ps) then return nil end
    local r = rankAll()[U.key(ps)]
    if not r then return nil end
    return r.pos, r.global, r.of
end

-- soloscore (#70): this world's sets {owner = pnum, ps = {PlayerState...: the human first}} (nil when no instances run)
function M.setList()
    if not M.active() then return nil end
    return race.sets
end

function M.setOf(ps)
    if not M.active() or not U.ok(ps) then return nil end
    return race.setOf[U.key(ps)]
end

-- the set owner's pnum of a racer's set (nil when no instances run / not in a set)
function M.ownerOf(ps)
    local s = M.setOf(ps)
    if not s then return nil end
    local set = race.sets[s]
    return set and set.owner or nil
end

-- soloscore: do two racers race in the same instance? -> true | false | nil (no instances, or a racer in no set)
function M.sameSet(a, b)
    local sa, sb = M.setOf(a), M.setOf(b)
    if sa == nil or sb == nil then return nil end
    return sa == sb
end

-- couchrules (D3 plane test) at a human's finish: his OWN race's result. -> won (bool), own place, note
function M.finishOf(h)
    if not M.active() then return nil end
    posCache.at = -1e12
    local lp, gp, of = M.localPosition(h.ps)
    local fail = tonumber(h.fail) or 0
    local t = nil
    pcall(function() t = tonumber(h.rec.EventFinishTime) end)
    local targetOk = (math.floor(fail) & FAIL_TARGET) == 0
    local won = lp == 1 and targetOk
    for i = #race.finish, 1, -1 do if race.finish[i].pnum == h.pnum then table.remove(race.finish, i) end end
    race.finish[#race.finish + 1] = { pnum = h.pnum, pos = lp, global = gp, won = won, how = "finished" }
    local note = string.format("P%s finished his own race: place %s of %s (global %s), time %s, fail reasons %d "
        .. "(target %s) -> %s", tostring(h.pnum), tostring(lp), tostring(of), tostring(gp),
        t and string.format("%.2f", t) or "?", math.floor(fail), targetOk and "ok" or "missed", won and "WON" or "not won")
    U.log(TAG, "%s", note)
    return won, lp, note
end

---------------------------------------------------------------------------------------------------- lifecycle
local function dropHidden(why)
    if not (race and race.ok and race.gen == St.worldGen) then return end
    for s, pc in pairs(race.owner or {}) do
        if U.ok(pc) and race.hid[s] then
            pcall(function() pc.HiddenActors:Empty() end)
        end
    end
    U.log(TAG, "per-view hide lists emptied (%s)", tostring(why))
end

function M.onPhase(new, old)
    if new == "OTHER" or new == "FRONTEND" then
        if plan then M.reset("phase " .. new) end
        return
    end
    if not plan then return end
    if new == "PRERACE" or new == "RACING" then
        U.mod("sched").after("instances.assign", 800, function() U.try(TAG, M.assign, new) end)
    end
    if new == "POSTRACE" and race and race.ok then
        -- AUTO-150d: a finish taken by the leave watch (no finishOf verdict) re-read from the settled places
        M._posFresh()
        for _, f in ipairs(race.finish) do
            if f.how == "finished" and f.global == nil then
                local set = nil
                for _, st in ipairs(race.sets) do if st.owner == f.pnum then set = st end end
                local lp = set and M.localPosition(set.ps[1]) or nil
                if lp and lp ~= f.pos then
                    U.log(TAG, "P%d's place at the finish %s -> %d (settled places)", f.pnum, tostring(f.pos), lp)
                    f.pos = lp
                end
            end
        end
        local parts = {}
        for _, f in ipairs(race.finish) do
            parts[#parts + 1] = string.format("P%d %s%s%s", f.pnum, f.pos and ("place " .. f.pos) or "?",
                (f.how and f.how ~= "finished") and (" " .. f.how) or "", f.won and " (won)" or "")
        end
        U.log(TAG, "race over: %s", #parts > 0 and table.concat(parts, ", ") or "no human finish seen")
    end
end

function M.init()
    -- #84 b / #85: new hazard / ability actors report themselves (store only); once per game session (hot reloads
    -- re-run init: the callback goes through U.mod so a reloaded module gets the calls)
    if not _G.SWGRCouch_hazNotify and type(NotifyOnNewObject) == "function" then
        local okAll = true
        for _, path in ipairs(M.HAZ_PATHS) do
            okAll = pcall(NotifyOnNewObject, path, function(obj)
                pcall(function() U.mod("instances")._hazSeen(obj) end)
            end) and okAll
        end
        _G.SWGRCouch_hazNotify = okAll
        U.log(TAG, "hazards per copy: NotifyOnNewObject on %d class(es) %s", #M.HAZ_PATHS, okAll and "installed" or "FAILED")
    end
    U.hook("/Script/Griffin.AbilityShockwaveSource:Multi_AddVehicle", {
        pre = function(ctx, veh, strength) U.try(TAG, M.onShockwaveAdd, ctx, veh, strength) end }, TAG)
    U.hook("/Script/Griffin.VehicleGameplayComponent:Server_OnVehicleDamaged", {
        pre = function(ctx, victim, inst, dmg) U.try(TAG, M.onDamaged, ctx, victim, inst, dmg) end }, TAG)
    U.hook("/Script/Griffin.VehicleBlameComponent:Server_AddBlameContributor", {
        pre = function(ctx, aggr) U.try(TAG, M.onBlame, ctx, aggr) end }, TAG)
    St.on("phase", TAG, function(new, old) U.try(TAG, M.onPhase, new, old) end)
    St.on("leaving", TAG, function() U.try(TAG, dropHidden, "leaving"); race = nil end)
    St.on("world", TAG, function() race = nil end)
end

return M
